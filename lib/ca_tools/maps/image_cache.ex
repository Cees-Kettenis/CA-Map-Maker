defmodule CATools.Maps.ImageCache do
  @moduledoc "Stores processed meetup images locally, sharing downloads across maps."
  require Logger
  import Ecto.Query
  alias CATools.Maps.{CachedImage, ImageProcessor, ImageURL, MapPoint, UserMap}
  alias CATools.Repo
  @limit 5_000_000

  @doc "Returns the image storage directory, configurable for persistent deployments."
  @spec directory() :: String.t()
  def directory do
    Application.get_env(:ca_tools, :image_storage_path, Path.expand("storage/meetup_images"))
  end

  @doc "Returns a stable key for a validated upstream image URL."
  @spec key(String.t()) :: String.t()
  def key(url), do: :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)

  @doc "Stores a bounded raster image upload in the same persistent storage as cached images."
  @spec store_upload(String.t(), pos_integer() | nil) :: {:ok, String.t()} | {:error, term()}
  def store_upload(path, user_id \\ nil) do
    with_storage_lock(fn ->
      with true <-
             is_nil(user_id) or
               Repo.exists?(from u in CATools.Accounts.User, where: u.id == ^user_id),
           {:ok, %{size: size}} when size > 0 and size <= @limit <- File.stat(path),
           {:ok, body} <- File.read(path),
           type when is_binary(type) <- content_type(body),
           {:ok, body} <- ImageProcessor.process(body) do
        id = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        with :ok <- File.mkdir_p(directory()),
             :ok <- write_file(id, body),
             {:ok, _} <-
               Repo.insert(
                 %CachedImage{
                   id: id,
                   content_type: "image/webp",
                   processing_version: 2,
                   status: "saved",
                   bytes: byte_size(body),
                   attempted_at: DateTime.utc_now(:second)
                 },
                 conflict_target: [:id],
                 on_conflict:
                   {:replace,
                    [
                      :content_type,
                      :processing_version,
                      :status,
                      :bytes,
                      :attempted_at,
                      :error_code,
                      :error_message
                    ]}
               ) do
          if user_id do
            Repo.insert_all(CATools.Maps.ImageUpload, [%{user_id: user_id, image_id: id}],
              on_conflict: :nothing
            )
          end

          {:ok, id}
        end
      else
        _ -> {:error, :invalid_image}
      end
    end)
  end

  @doc "Queues uncached images, sharing the same download across maps and accounts."
  @spec enqueue([term()]) :: :ok
  def enqueue(values) do
    with_storage_lock(fn ->
      Enum.each(Enum.uniq(values), fn value ->
        case ImageURL.normalize(value) do
          nil ->
            :ok

          url ->
            if referenced_url?(url) and not expired_url?(url) do
              Repo.delete_all(
                from i in CachedImage, where: i.id == ^key(url) and i.status == "expired"
              )

              if not Repo.exists?(from i in CachedImage, where: i.id == ^key(url)),
                do: Oban.insert!(CATools.Campfire.ImageCacheJob.new(%{"url" => url}))
            end
        end
      end)

      :ok
    end)
  end

  @doc "Queues eligible imported images and community logos for local storage."
  @spec enqueue_existing() :: :ok
  def enqueue_existing do
    Repo.all(from p in MapPoint, select: {p.cover_photo_url, p.host_avatar_url})
    |> Enum.flat_map(fn {cover, avatar} -> [cover, avatar] end)
    |> Kernel.++(Repo.all(from c in CATools.Communities.Community, select: c.avatar_url))
    |> enqueue()
  end

  @doc "Looks up local URLs in one query without fetching any remote images."
  @spec local_urls([term()]) :: map()
  def local_urls(values) do
    urls = Enum.map(values, &ImageURL.normalize/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    ids = Enum.map(urls, &key/1)

    available =
      Repo.all(
        from i in CachedImage,
          where: i.id in ^ids and not is_nil(i.content_type),
          select: {i.id, i.processing_version}
      )
      |> Map.new()

    Map.new(urls, fn url ->
      id = key(url)

      {url,
       if(Map.has_key?(available, id) and File.regular?(Path.join(directory(), id)),
         do: "/media/meetups/#{id}" <> if(available[id], do: "?v=#{available[id]}", else: "")
       )}
    end)
  end

  @doc "Returns the file and content type for a stored image, never fetching on a page request."
  @spec file(term()) :: {:ok, String.t(), String.t()} | :error
  def file(id) do
    if is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id) do
      case Repo.get(CachedImage, id) do
        %CachedImage{content_type: type} when is_binary(type) ->
          path = Path.join(directory(), id)
          if File.regular?(path), do: {:ok, path, type}, else: :error

        _ ->
          :error
      end
    else
      :error
    end
  end

  @doc "Makes one bounded download attempt per retained URL. Expired images may be fetched for newer meetups; failures require a manual retry."
  @spec fetch(term(), keyword()) :: :ok
  def fetch(value, opts \\ []) do
    with_storage_lock(fn ->
      case ImageURL.normalize(value) do
        nil ->
          :ok

        url ->
          id = key(url)

          eligible =
            Keyword.get(opts, :revive_expired, false) or
              (not expired_url?(url) and
                 (not Keyword.get(opts, :require_reference, false) or referenced_url?(url)))

          if eligible do
            Repo.delete_all(from i in CachedImage, where: i.id == ^id and i.status == "expired")
          end

          if not Keyword.get(opts, :require_reference, false) or referenced_url?(url) do
            {claimed, _} =
              Repo.insert_all(
                CachedImage,
                [%{id: id, attempted_at: DateTime.utc_now(:second)}],
                on_conflict: :nothing
              )

            previous = if Keyword.get(opts, :refresh, false), do: Repo.get(CachedImage, id)

            claimed =
              if claimed == 0 and eligible and Keyword.get(opts, :refresh, false) do
                {updated, _} =
                  Repo.update_all(
                    from(i in CachedImage,
                      where:
                        i.id == ^id and i.status == "saved" and
                          (is_nil(i.processing_version) or i.processing_version < 2) and
                          (is_nil(i.error_code) or i.error_code != "upgrade_failed")
                    ),
                    set: [status: "downloading"]
                  )

                updated
              else
                claimed
              end

            if claimed == 1 and eligible do
              result = download(url, opts)

              result =
                case result do
                  {:redirect, target} ->
                    Repo.update_all(from(i in CachedImage, where: i.id == ^id),
                      set: [redirect_url: target]
                    )

                    follow_cached_redirect(target, opts)

                  other ->
                    other
                end

              fields =
                case result do
                  {:ok, body, type} ->
                    with :ok <- File.mkdir_p(directory()),
                         :ok <- write_file(id, body) do
                      Logger.info("Meetup image #{id}: saved #{byte_size(body)} bytes")

                      [
                        status: "saved",
                        content_type: type,
                        processing_version: 2,
                        bytes: byte_size(body),
                        http_status: 200,
                        error_code: nil,
                        error_message: nil
                      ]
                    else
                      {:error, reason} ->
                        [
                          status: "failed",
                          error_code: "storage_error",
                          error_message: "Could not save image: #{:file.format_error(reason)}"
                        ]
                    end

                  {:error, fields} ->
                    [status: "failed"] ++ fields
                end

              fields =
                if fields[:status] == "failed" and match?(%CachedImage{status: "saved"}, previous) do
                  [
                    status: "saved",
                    error_code: "upgrade_failed",
                    error_message: fields[:error_message]
                  ]
                else
                  fields
                end

              if fields[:status] == "failed" or fields[:error_code] == "upgrade_failed",
                do: Logger.warning("Meetup image #{id}: #{fields[:error_message]}")

              Repo.update_all(from(i in CachedImage, where: i.id == ^id), set: fields)
            else
              if claimed == 1 and not eligible,
                do:
                  Repo.update_all(from(i in CachedImage, where: i.id == ^id),
                    set: [status: "expired"]
                  )

              case Repo.get(CachedImage, id) do
                %CachedImage{content_type: nil, redirect_url: target, status: status}
                when is_binary(target) and status != "expired" ->
                  case follow_cached_redirect(target, opts) do
                    {:ok, body, type} ->
                      with :ok <- File.mkdir_p(directory()),
                           :ok <- write_file(id, body) do
                        Repo.update_all(from(i in CachedImage, where: i.id == ^id),
                          set: [
                            status: "saved",
                            content_type: type,
                            processing_version: 2,
                            bytes: byte_size(body),
                            error_code: nil,
                            error_message: nil
                          ]
                        )
                      end

                    _ ->
                      :ok
                  end

                _ ->
                  :ok
              end
            end
          end

          :ok
      end
    end)
  end

  @doc "Queues a user-requested retry of failed images on an owned map. Saved images are preserved."
  @spec retry_failed(CATools.Accounts.Scope.t(), term()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def retry_failed(scope, map_id) do
    case CATools.Maps.get_map(scope, map_id) do
      nil ->
        {:error, :not_found}

      map ->
        urls =
          Enum.flat_map(map.points, &[&1.cover_photo_url, &1.host_avatar_url])
          |> Enum.map(&ImageURL.normalize/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&expired_url?/1)
          |> Enum.uniq()

        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])
          ids = Enum.map(urls, &key/1)

          failed =
            Repo.all(
              from i in CachedImage,
                where: i.id in ^ids and i.status == "failed" and is_nil(i.content_type),
                select: i.id,
                lock: "FOR UPDATE"
            )

          Repo.delete_all(from i in CachedImage, where: i.id in ^failed)
          selected = Enum.filter(urls, &(key(&1) in failed))
          enqueue(selected)
          {:ok, length(selected)}
        end)
    end
  end

  @doc "Summarizes local image downloads for a map, including failures and missing saved files."
  @spec summary([MapPoint.t()]) :: map()
  def summary(points) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -30 * 86_400, :second)

    urls =
      points
      |> Enum.reject(fn point ->
        ended_at = point.ends_at || point.starts_at
        ended_at && DateTime.compare(ended_at, cutoff) == :lt
      end)
      |> Enum.flat_map(&[&1.cover_photo_url, &1.host_avatar_url])
      |> Enum.map(&ImageURL.normalize/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ids = Enum.map(urls, &key/1)
    records = Repo.all(from i in CachedImage, where: i.id in ^ids and i.status != "expired")

    saved =
      Enum.count(
        records,
        &(not is_nil(&1.content_type) and File.regular?(Path.join(directory(), &1.id)))
      )

    failures =
      Enum.filter(
        records,
        &(&1.status == "failed" or
            (not is_nil(&1.content_type) and not File.regular?(Path.join(directory(), &1.id))))
      )

    %{
      total: length(ids),
      saved: saved,
      failed: length(failures),
      pending: length(ids) - saved - length(failures),
      errors:
        Enum.map(
          failures,
          &(&1.error_message || "Saved image file is missing from local storage.")
        )
        |> Enum.uniq()
    }
  end

  @doc "Removes unreferenced cached files and images used only by meetups more than 30 days past their end."
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(now \\ DateTime.utc_now(:second)) do
    with_storage_lock(fn ->
      cutoff = DateTime.add(now, -30 * 86_400, :second)
      grace = DateTime.add(now, -86_400, :second)

      urls =
        Repo.all(
          from p in MapPoint,
            where:
              is_nil(fragment("COALESCE(?, ?)", p.ends_at, p.starts_at)) or
                fragment("COALESCE(?, ?)", p.ends_at, p.starts_at) >= ^cutoff,
            select: {p.cover_photo_url, p.host_avatar_url}
        )
        |> Enum.flat_map(fn {cover, avatar} -> [cover, avatar] end)
        |> Kernel.++(Repo.all(from c in CATools.Communities.Community, select: c.avatar_url))
        |> Enum.map(&ImageURL.normalize/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&key/1)

      retained =
        MapSet.new(
          urls ++ Repo.all(from m in UserMap, where: not is_nil(m.image_id), select: m.image_id)
        )

      Repo.all(from i in CachedImage, where: i.status == "saved" and i.attempted_at <= ^grace)
      |> Enum.reject(&MapSet.member?(retained, &1.id))
      |> Enum.reduce(0, fn image, count ->
        case File.rm(Path.join(directory(), image.id)) do
          result when result in [:ok, {:error, :enoent}] ->
            Repo.update_all(from(i in CachedImage, where: i.id == ^image.id),
              set: [
                status: "expired",
                redirect_url: nil,
                content_type: nil,
                bytes: nil,
                error_code: nil,
                error_message: nil
              ]
            )

            count + 1

          {:error, reason} ->
            Logger.warning(
              "Could not remove cached image #{image.id}: #{:file.format_error(reason)}"
            )

            count
        end
      end)
    end)
  end

  @doc "Upgrades a bounded batch of cached images, fetching originals again when a previous resize discarded detail."
  @spec process_existing(pos_integer(), keyword()) :: non_neg_integer()
  def process_existing(limit \\ 20, opts \\ []) do
    with_storage_lock(fn ->
      images =
        Repo.all(
          from i in CachedImage,
            where:
              i.status == "saved" and (is_nil(i.processing_version) or i.processing_version < 2) and
                (is_nil(i.error_code) or i.error_code != "upgrade_failed"),
            order_by: i.id,
            limit: ^limit
        )

      source_urls =
        Repo.all(from p in MapPoint, select: {p.cover_photo_url, p.host_avatar_url})
        |> Enum.flat_map(fn {cover, avatar} -> [cover, avatar] end)
        |> Kernel.++(Repo.all(from c in CATools.Communities.Community, select: c.avatar_url))
        |> Kernel.++(
          Repo.all(
            from i in CachedImage, where: not is_nil(i.redirect_url), select: i.redirect_url
          )
        )
        |> Enum.map(&ImageURL.normalize/1)
        |> Enum.reject(&is_nil/1)
        |> Map.new(&{key(&1), &1})

      Enum.each(images, fn image ->
        url = Map.get(source_urls, image.id)

        if (image.processing_version == 1 and url) && not expired_url?(url) do
          fetch(url, Keyword.put(opts, :refresh, true))
        else
          with {:ok, body} <- File.read(Path.join(directory(), image.id)),
               {:ok, processed} <- ImageProcessor.process(body),
               :ok <- write_file(image.id, processed) do
            Repo.update_all(from(i in CachedImage, where: i.id == ^image.id),
              set: [
                content_type: "image/webp",
                bytes: byte_size(processed),
                processing_version: 2
              ]
            )
          else
            {:error, _reason} ->
              Repo.update_all(from(i in CachedImage, where: i.id == ^image.id),
                set: [
                  status: "failed",
                  content_type: nil,
                  error_code: "processing_error",
                  error_message: "Existing image could not be processed."
                ]
              )

              File.rm(Path.join(directory(), image.id))
          end
        end
      end)

      length(images)
    end)
  end

  @doc "Serializes cache writes and account cleanup across application processes."
  @spec with_storage_lock((-> result)) :: result | {:error, term()} when result: term()
  def with_storage_lock(fun) do
    case Repo.transact(fn ->
           Repo.query!("SELECT pg_advisory_xact_lock(73192, 0)")
           {:ok, fun.()}
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reports whether a remote image still belongs to an existing meetup or community."
  @spec referenced_url?(String.t()) :: boolean()
  def referenced_url?(url) do
    Repo.exists?(
      from p in MapPoint, where: p.cover_photo_url == ^url or p.host_avatar_url == ^url
    ) or
      Repo.exists?(from c in CATools.Communities.Community, where: c.avatar_url == ^url)
  end

  defp expired_url?(url) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -30 * 86_400, :second)
    points = from p in MapPoint, where: p.cover_photo_url == ^url or p.host_avatar_url == ^url

    Repo.exists?(points) and
      not Repo.exists?(
        from p in points,
          where:
            is_nil(fragment("COALESCE(?, ?)", p.ends_at, p.starts_at)) or
              fragment("COALESCE(?, ?)", p.ends_at, p.starts_at) >= ^cutoff
      ) and
      not Repo.exists?(from c in CATools.Communities.Community, where: c.avatar_url == ^url) and
      not Repo.exists?(from m in UserMap, where: m.image_id == ^key(url))
  end

  defp write_file(id, body) do
    path = Path.join(directory(), id)
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    result = with :ok <- File.write(temporary, body), do: File.rename(temporary, path)
    File.rm(temporary)
    result
  end

  defp follow_cached_redirect(target, opts) do
    remaining = Keyword.get(opts, :redirects_left, 5)

    if remaining > 0 do
      fetch(target, Keyword.merge(opts, redirects_left: remaining - 1, revive_expired: true))

      with {:ok, path, _type} <- file(key(target)), {:ok, body} <- File.read(path) do
        cached = Repo.get!(CachedImage, key(target))

        case if(cached.processing_version == 2,
               do: {:ok, body},
               else: ImageProcessor.process(body)
             ) do
          {:ok, processed} ->
            {:ok, processed, "image/webp"}

          {:error, _} ->
            {:error,
             [
               error_code: "processing_error",
               error_message: "Redirect image could not be processed."
             ]}
        end
      else
        _ ->
          {:error,
           [
             error_code: "redirect_failed",
             error_message: "Redirect destination could not be cached."
           ]}
      end
    else
      {:error,
       [error_code: "redirect_limit", error_message: "Image exceeded the redirect limit."]}
    end
  end

  defp download(url, opts) do
    with :ok <- CATools.Campfire.LinkResolver.ensure_public_destination(url, opts),
         {:ok, response} <-
           Req.get(
             url,
             [
               retry: false,
               redirect: false,
               decode_body: false,
               receive_timeout: 15_000,
               into: fn {:data, chunk}, {request, response} ->
                 body = (response.body || "") <> chunk

                 if byte_size(body) > @limit,
                   do: {:halt, {request, %{response | status: 413, body: ""}}},
                   else: {:cont, {request, %{response | body: body}}}
               end
             ] ++ Keyword.get(opts, :request_options, [])
           ) do
      case response do
        %{status: 200, body: body} when is_binary(body) and byte_size(body) <= @limit ->
          case content_type(body) do
            nil ->
              {:error,
               [
                 http_status: 200,
                 error_code: "unsupported_image",
                 error_message:
                   "Downloaded response is not a supported PNG, JPEG, GIF or WebP image."
               ]}

            _type ->
              case ImageProcessor.process(body) do
                {:ok, processed} ->
                  {:ok, processed, "image/webp"}

                {:error, _reason} ->
                  {:error,
                   [
                     error_code: "processing_error",
                     error_message:
                       "Image could not be decoded or compressed within the image limits."
                   ]}
              end
          end

        %{status: status} when status in [301, 302, 303, 307, 308] ->
          location = Req.Response.get_header(response, "location") |> List.first()

          target =
            if is_binary(location),
              do: URI.merge(url, location) |> URI.to_string() |> ImageURL.normalize()

          if target,
            do: {:redirect, target},
            else:
              {:error,
               [
                 http_status: status,
                 error_code: "unsafe_redirect",
                 error_message: "Image redirect did not contain a valid HTTPS destination."
               ]}

        %{status: status} ->
          {:error,
           [
             http_status: status,
             error_code: "http_error",
             error_message: "Image download returned HTTP #{status}."
           ]}
      end
    else
      {:error, %{message: message, code: code}} ->
        {:error, [error_code: code, error_message: message]}

      {:error, exception} ->
        {:error,
         [
           error_code: "network_error",
           error_message: "Image request failed: #{Exception.message(exception)}"
         ]}
    end
  end

  defp content_type(body) do
    case body do
      <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> -> "image/png"
      <<255, 216, 255, _::binary>> -> "image/jpeg"
      <<"GIF", version::binary-size(3), _::binary>> when version in ["87a", "89a"] -> "image/gif"
      <<"RIFF", _::binary-size(4), "WEBP", _::binary>> -> "image/webp"
      _ -> nil
    end
  end
end
