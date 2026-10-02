defmodule CATools.Maps.ImageCache do
  @moduledoc "Stores meetup images locally with at most one upstream request per distinct URL."
  require Logger
  import Ecto.Query
  alias CATools.Maps.{CachedImage, ImageURL, MapPoint}
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
  @spec store_upload(String.t()) :: {:ok, String.t()} | {:error, term()}
  def store_upload(path) do
    with {:ok, %{size: size}} when size > 0 and size <= @limit <- File.stat(path),
         {:ok, body} <- File.read(path),
         type when is_binary(type) <- content_type(body) do
      id = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      with :ok <- File.mkdir_p(directory()),
           :ok <- File.write(Path.join(directory(), id), body),
           {:ok, _} <-
             Repo.insert(
               %CachedImage{
                 id: id,
                 content_type: type,
                 status: "saved",
                 bytes: byte_size(body),
                 attempted_at: DateTime.utc_now(:second)
               },
               on_conflict: :nothing
             ) do
        {:ok, id}
      end
    else
      _ -> {:error, :invalid_image}
    end
  end

  @doc "Queues uncached images, sharing the same download across maps and accounts."
  @spec enqueue([term()]) :: :ok
  def enqueue(values) do
    Enum.each(Enum.uniq(values), fn value ->
      case ImageURL.normalize(value) do
        nil ->
          :ok

        url ->
          if not Repo.exists?(from i in CachedImage, where: i.id == ^key(url)),
            do: Oban.insert!(CATools.Campfire.ImageCacheJob.new(%{"url" => url}))
      end
    end)

    :ok
  end

  @doc "Queues existing imported images so older meetups also use local files."
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
        from i in CachedImage, where: i.id in ^ids and not is_nil(i.content_type), select: i.id
      )
      |> MapSet.new()

    Map.new(urls, fn url ->
      id = key(url)

      {url,
       if(MapSet.member?(available, id) and File.regular?(Path.join(directory(), id)),
         do: "/media/meetups/#{id}"
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

  @doc "Makes one bounded download attempt. Failures are recorded and never retried automatically."
  @spec fetch(term(), keyword()) :: :ok
  def fetch(value, opts \\ []) do
    case ImageURL.normalize(value) do
      nil ->
        :ok

      url ->
        id = key(url)

        {claimed, _} =
          Repo.insert_all(
            CachedImage,
            [%{id: id, attempted_at: DateTime.utc_now(:second)}],
            on_conflict: :nothing
          )

        if claimed == 1 do
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
                     :ok <- File.write(Path.join(directory(), id), body) do
                  Logger.info("Meetup image #{id}: saved #{byte_size(body)} bytes")
                  [status: "saved", content_type: type, bytes: byte_size(body), http_status: 200]
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

          if fields[:status] == "failed",
            do: Logger.warning("Meetup image #{id}: #{fields[:error_message]}")

          Repo.update_all(from(i in CachedImage, where: i.id == ^id), set: fields)
        else
          case Repo.get(CachedImage, id) do
            %CachedImage{content_type: nil, redirect_url: target} when is_binary(target) ->
              case follow_cached_redirect(target, opts) do
                {:ok, body, type} ->
                  with :ok <- File.mkdir_p(directory()),
                       :ok <- File.write(Path.join(directory(), id), body) do
                    Repo.update_all(from(i in CachedImage, where: i.id == ^id),
                      set: [
                        status: "saved",
                        content_type: type,
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

        :ok
    end
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
    urls =
      Enum.flat_map(points, &[&1.cover_photo_url, &1.host_avatar_url])
      |> Enum.map(&ImageURL.normalize/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ids = Enum.map(urls, &key/1)
    records = Repo.all(from i in CachedImage, where: i.id in ^ids)

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

  defp follow_cached_redirect(target, opts) do
    remaining = Keyword.get(opts, :redirects_left, 5)

    if remaining > 0 do
      fetch(target, Keyword.put(opts, :redirects_left, remaining - 1))

      with {:ok, path, type} <- file(key(target)), {:ok, body} <- File.read(path) do
        {:ok, body, type}
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

            type ->
              {:ok, body, type}
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
