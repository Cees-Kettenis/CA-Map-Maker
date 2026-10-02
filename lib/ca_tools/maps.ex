defmodule CATools.Maps do
  @moduledoc """
  The Maps context.
  """

  import Ecto.Query, warn: false

  alias CATools.Accounts.Scope
  alias CATools.Campfire.{BatchScheduler, ImportJob, LinkResolver}
  alias CATools.Maps.{ImportBatch, MapPoint, MapSource, UserMap}
  alias CATools.RateLimiter
  alias CATools.Repo
  alias Ecto.Changeset

  @type source_url_error() :: String.t()
  @type source_url_result() :: {:ok, [String.t()]} | {:error, [source_url_error()]}

  @doc """
  Lists maps owned by the current scope's user.
  """
  @spec list_maps(Scope.t() | nil) :: [UserMap.t()]
  def list_maps(scope) do
    case scope do
      %Scope{user: %{id: user_id}} ->
        UserMap
        |> where([map], map.user_id == ^user_id)
        |> order_by([map], desc: map.inserted_at)
        |> preload([:sources, :batches, :community])
        |> Repo.all()
        |> then(fn maps ->
          images =
            CATools.Maps.ImageCache.local_urls(
              Enum.map(maps, &(&1.community && &1.community.avatar_url))
            )

          Enum.map(
            Enum.map(maps, &CATools.MeetupMaps.load_events/1),
            fn map ->
              image =
                if map.community,
                  do: Map.get(images, map.community.avatar_url),
                  else: image_url(map)

              %{map | community_icon_url: image}
            end
          )
        end)

      _ ->
        []
    end
  end

  @doc """
  Gets a single map owned by the current scope's user.
  """
  @spec get_map(Scope.t() | nil, term()) :: UserMap.t() | nil
  def get_map(scope, id) do
    case {authorized_user_id(scope), Ecto.Type.cast(:id, id)} do
      {{:ok, user_id}, {:ok, map_id}} when is_integer(map_id) and map_id > 0 ->
        UserMap
        |> where([map], map.id == ^map_id and map.user_id == ^user_id)
        |> preload([:sources, :points, :batches, :community])
        |> Repo.one()
        |> then(fn map -> if map, do: CATools.MeetupMaps.load_events(map) end)

      _ ->
        nil
    end
  end

  @doc """
  Returns a changeset for creating a map owned by the current scope's user.
  """
  @spec change_map(Scope.t() | nil, map()) :: Changeset.t()
  def change_map(scope, attrs \\ %{}) do
    case authorized_user_id(scope) do
      {:ok, user_id} ->
        %UserMap{user_id: user_id}
        |> UserMap.creation_changeset(attrs)
        |> validate_source_urls()

      :error ->
        %UserMap{}
        |> UserMap.creation_changeset(attrs)
        |> Changeset.add_error(:base, "You must log in to manage maps.")
    end
  end

  @doc """
  Creates a map, its source URL records, and import jobs for the current scope's user.
  """
  @spec create_map(Scope.t() | nil, map()) ::
          {:ok, UserMap.t()}
          | {:error, Changeset.t()}
          | {:error, :unauthorized}
          | {:error, {:rate_limited, non_neg_integer()}}
  def create_map(scope, attrs) do
    with {:ok, user_id} <- authorized_user_id(scope),
         :ok <- RateLimiter.check(:map_create_user, Integer.to_string(user_id)) do
      changeset =
        %UserMap{user_id: user_id}
        |> UserMap.creation_changeset(attrs)
        |> validate_source_urls()

      case changeset.valid? do
        true ->
          case normalize_source_urls(Changeset.get_field(changeset, :source_urls_input)) do
            {:ok, normalized_urls} ->
              create_map_with_sources(changeset, normalized_urls)

            {:error, messages} ->
              {:error,
               Enum.reduce(messages, changeset, fn message, current_changeset ->
                 Changeset.add_error(current_changeset, :source_urls_input, message)
               end)}
          end

        false ->
          {:error, changeset}
      end
    else
      :error -> {:error, :unauthorized}
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
    |> then(fn result ->
      case result do
        {:ok, map} -> notify(map.user_id)
        _ -> :ok
      end

      result
    end)
  end

  @doc """
  Normalizes a multi-line Campfire link input into unique, supported source URLs.
  """
  @spec normalize_source_urls(term()) :: source_url_result()
  def normalize_source_urls(raw_input) do
    case raw_input do
      value when is_binary(value) ->
        lines =
          value
          |> String.split(~r/\r\n|\n|\r/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        validate_source_url_lines(lines)

      _ ->
        {:error, ["Enter at least one Campfire link."]}
    end
  end

  @doc "Finds a public map by its unguessable share slug. Private maps return nil."
  @spec get_public_map(String.t()) :: UserMap.t() | nil
  def get_public_map(slug) do
    Repo.one(
      from m in UserMap,
        where: m.public_slug == ^slug and m.visibility == :public,
        preload: [:points, :sources, :community]
    )
    |> then(fn map -> if map, do: CATools.MeetupMaps.load_events(map) end)
  end

  @doc "Returns a locally stored group logo or uploaded image for a map."
  @spec image_url(UserMap.t()) :: String.t() | nil
  def image_url(map) do
    case map.community do
      %CATools.Communities.Community{avatar_url: avatar} ->
        Map.get(CATools.Maps.ImageCache.local_urls([avatar]), avatar)

      _ ->
        case CATools.Maps.ImageCache.file(map.image_id) do
          {:ok, _, _} -> "/media/meetups/#{map.image_id}"
          :error -> nil
        end
    end
  end

  @doc "Returns a validated changeset for editing an owned map."
  @spec change_existing_map(UserMap.t(), map()) :: Changeset.t()
  def change_existing_map(map, attrs \\ %{}), do: UserMap.changeset(map, attrs)

  @doc "Updates an owned map's name, description and visibility."
  @spec update_map(Scope.t() | nil, term(), map()) :: {:ok, UserMap.t()} | {:error, term()}
  def update_map(scope, id, attrs) do
    case get_map(scope, id) do
      nil ->
        {:error, :not_found}

      map ->
        changeset = UserMap.changeset(map, attrs)

        community? =
          Repo.exists?(from c in CATools.Communities.Community, where: c.map_id == ^map.id)

        changeset =
          if community? and Changeset.get_field(changeset, :visibility) == :public do
            Changeset.add_error(
              changeset,
              :visibility,
              "Community maps use invitation-only sharing."
            )
          else
            changeset
          end

        slug =
          case {Changeset.get_field(changeset, :visibility), map.public_slug} do
            {:public, nil} -> maybe_generate_public_slug(:public)
            {_, slug} -> slug
          end

        changeset |> Changeset.put_change(:public_slug, slug) |> Repo.update()
    end
    |> then(fn result ->
      case result do
        {:ok, map} -> notify(map.user_id)
        _ -> :ok
      end

      result
    end)
  end

  @doc "Deletes an owned map, its sources, batches and points."
  @spec delete_map(Scope.t() | nil, term()) :: {:ok, UserMap.t()} | {:error, term()}
  def delete_map(scope, id) do
    case get_map(scope, id) do
      nil ->
        {:error, :not_found}

      map ->
        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [map.user_id])
          community = Repo.get_by(CATools.Communities.Community, map_id: map.id)

          if community do
            Repo.all(
              from s in CATools.Maps.CommunitySelection,
                where: s.community_id == ^community.id,
                select: s.map_id
            )
          else
            []
          end

          if community, do: Repo.delete!(community)

          case Repo.delete(map) do
            {:ok, deleted} ->
              {:ok, deleted}

            {:error, error} ->
              Repo.rollback(error)
          end
        end)
    end
    |> then(fn result ->
      case result do
        {:ok, map} -> notify(map.user_id)
        _ -> :ok
      end

      result
    end)
  end

  @doc "Queues failed or stale sources for another controlled import."
  @spec refresh_map(Scope.t() | nil, term(), :failed | :stale | :all) ::
          {:ok, ImportBatch.t()} | {:error, term()}
  def refresh_map(scope, id, mode \\ :failed) do
    case get_map(scope, id) do
      nil ->
        {:error, :not_found}

      map ->
        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [map.user_id])
          cutoff = DateTime.add(DateTime.utc_now(:second), -86_400, :second)

          candidates =
            from s in MapSource,
              where: s.map_id == ^map.id and s.status in [:fetched, :failed, :skipped]

          candidates =
            case mode do
              :failed ->
                from s in candidates, where: s.status in [:failed, :skipped]

              :stale ->
                ended =
                  from p in MapPoint,
                    where: not is_nil(p.ends_at) and p.ends_at <= ^DateTime.utc_now(:second),
                    select: p.map_source_id

                from s in candidates,
                  where:
                    fragment("GREATEST(?, ?)", s.last_fetched_at, s.updated_at) <= ^cutoff and
                      s.id not in subquery(ended)

              :all ->
                candidates
            end

          ids = Repo.all(from s in candidates, select: s.id, lock: "FOR UPDATE")
          if ids == [], do: Repo.rollback(:no_sources)
          cancel_source_jobs(ids)

          {:ok, batch} =
            Repo.insert(
              Changeset.change(%ImportBatch{},
                user_id: map.user_id,
                map_id: map.id,
                total_count: length(ids)
              )
            )

          Repo.update_all(from(s in MapSource, where: s.id in ^ids),
            set: [
              status: :pending,
              next_fetch_at: nil,
              import_batch_id: batch.id,
              error_code: nil,
              error_message: nil
            ]
          )

          %{"user_id" => map.user_id} |> BatchScheduler.new() |> Oban.insert!()
          {:ok, batch}
        end)
    end
  end

  @doc "Notifies connected pages when this owner's maps change."
  @spec notify(integer()) :: :ok
  def notify(user_id), do: Phoenix.PubSub.broadcast(CATools.PubSub, "maps:#{user_id}", :refresh)

  @doc "Subscribes a connected page to map and locally stored image changes."
  @spec subscribe(integer()) :: :ok
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(CATools.PubSub, "maps:#{user_id}")
  end

  @doc "Queues an immediate owner-requested update without waiting for the daily schedule."
  @spec request_update(Scope.t(), term()) :: :ok | {:error, term()}
  def request_update(scope, id) do
    case get_map(scope, id) do
      nil ->
        {:error, :not_found}

      %UserMap{meetup_date: %Date{}} = map ->
        sources_by_map = Enum.group_by(map.sources, & &1.map_id, & &1.id)

        Enum.each(sources_by_map, fn {source_map, ids} ->
          queue_sources_now(scope, source_map, ids)
        end)

        if map.sources == [] do
          Enum.each(
            CATools.MeetupMaps.communities(scope, id),
            &CATools.Communities.check_now(scope, &1.id)
          )
        end

        notify(scope.user.id)

      map ->
        case map.community do
          %CATools.Communities.Community{} = c ->
            CATools.Communities.check_now(scope, c.id)

          _ ->
            queue_sources_now(scope, map.id, Enum.map(map.sources, & &1.id))
            notify(scope.user.id)
        end
    end
  end

  # Selecting existing source IDs lets linked maps refresh shared details only once.
  defp queue_sources_now(scope, map_id, ids) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])

      sources =
        Repo.all(
          from s in MapSource,
            where:
              s.map_id == ^map_id and s.id in ^ids and s.status in [:fetched, :failed, :skipped],
            lock: "FOR UPDATE"
        )

      if sources != [] do
        batch =
          Repo.insert!(
            Changeset.change(%ImportBatch{},
              user_id: scope.user.id,
              map_id: map_id,
              total_count: length(sources)
            )
          )

        source_ids = Enum.map(sources, & &1.id)
        cancel_source_jobs(source_ids)

        Repo.update_all(from(s in MapSource, where: s.id in ^source_ids),
          set: [
            status: :pending,
            import_batch_id: batch.id,
            next_fetch_at: DateTime.utc_now(:second),
            error_code: nil,
            error_message: nil
          ]
        )
      end

      # Initial imports may already be waiting in the regular scheduler.
      pending =
        Repo.all(
          from s in MapSource,
            where: s.map_id == ^map_id and s.id in ^ids and s.status == :pending
        )

      pending_ids = Enum.map(pending, & &1.id)

      Repo.update_all(from(s in MapSource, where: s.id in ^pending_ids),
        set: [next_fetch_at: DateTime.utc_now(:second)]
      )

      Oban.retry_all_jobs(
        from j in Oban.Job,
          where:
            j.worker == "CATools.Campfire.ImportJob" and j.state in ["scheduled", "retryable"] and
              fragment("(?->>'source_id')::bigint", j.args) in ^pending_ids
      )

      Enum.each(pending, fn s -> Oban.insert!(ImportJob.new(%{"source_id" => s.id})) end)
      {:ok, :queued}
    end)
  end

  @doc "Returns the next automatic update time for a map."
  @spec next_update_at(UserMap.t()) :: DateTime.t() | nil
  def next_update_at(map) do
    ended_ids =
      case map.points do
        points when is_list(points) ->
          points |> Enum.filter(&meetup_ended?/1) |> Enum.map(& &1.map_source_id) |> MapSet.new()

        _ ->
          MapSet.new()
      end

    source_dates =
      map.sources
      |> Enum.reject(&MapSet.member?(ended_ids, &1.id))
      |> Enum.map(fn source ->
        timestamps = [source.last_fetched_at, source.updated_at] |> Enum.reject(&is_nil/1)

        case Enum.max_by(timestamps, &DateTime.to_unix/1, fn -> nil end) do
          nil -> nil
          date -> DateTime.add(date, 86_400, :second)
        end
      end)

    dates =
      case {map.community, map.meetup_date} do
        {%CATools.Communities.Community{enabled: true, next_check_at: next}, _} ->
          [next | source_dates]

        {%CATools.Communities.Community{}, _} ->
          []

        {_, %Date{}} ->
          checks =
            Repo.all(
              from c in CATools.Communities.Community,
                join: s in CATools.Maps.CommunitySelection,
                on: s.community_id == c.id,
                where: s.map_id == ^map.id and c.user_id == ^map.user_id and c.enabled,
                select: c.next_check_at
            )

          checks ++ source_dates

        _ ->
          source_dates
      end

    dates |> Enum.reject(&is_nil/1) |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
  end

  @doc "Schedules one page update when its next meetup ends, without database polling."
  @spec schedule_expiry([map()], reference() | nil) :: reference() | nil
  def schedule_expiry(points, previous \\ nil) do
    if previous, do: Process.cancel_timer(previous)
    now = DateTime.utc_now()

    dates =
      Enum.map(points, & &1.ends_at)
      |> Enum.filter(&(match?(%DateTime{}, &1) and DateTime.compare(&1, now) == :gt))

    case Enum.min_by(dates, &DateTime.to_unix/1, fn -> nil end) do
      nil ->
        nil

      date ->
        Process.send_after(
          self(),
          :refresh,
          min(DateTime.diff(date, now, :millisecond) + 50, 4_294_967_295)
        )
    end
  end

  @doc "Reports whether the temporary development-only force-fetch control is enabled."
  @spec force_fetch_enabled?() :: boolean()
  def force_fetch_enabled? do
    Application.get_env(
      :ca_tools,
      :temporary_force_fetch_enabled,
      Application.get_env(:ca_tools, :dev_routes, false)
    )
  end

  @doc "Starts the pending sources in an owned batch immediately, bypassing the temporary scheduling wait."
  @spec force_fetch_batch(Scope.t() | nil, term(), term()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def force_fetch_batch(scope, map_id, batch_id) do
    with true <- force_fetch_enabled?(),
         %UserMap{} = map <- get_map(scope, map_id),
         {:ok, id} <- Ecto.Type.cast(:id, batch_id) do
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [map.user_id])
        batch = Repo.get_by(ImportBatch, id: id, map_id: map.id)

        if is_nil(batch) or batch.status not in [:queued, :processing],
          do: Repo.rollback(:not_pending)

        sources =
          Repo.all(
            from s in MapSource,
              where: s.import_batch_id == ^id and s.status == :pending,
              lock: "FOR UPDATE"
          )

        ids = Enum.map(sources, & &1.id)

        jobs =
          from j in Oban.Job,
            where:
              j.worker == "CATools.Campfire.ImportJob" and
                j.state in ["available", "scheduled", "executing", "retryable"],
            where: fragment("(?->>'source_id')::bigint", j.args) in ^ids

        existing_ids =
          Repo.all(from j in jobs, select: fragment("(?->>'source_id')::bigint", j.args))
          |> MapSet.new()

        new_sources = Enum.reject(sources, &MapSet.member?(existing_ids, &1.id))
        now = DateTime.utc_now(:second)

        if ids != [] do
          Repo.update_all(from(s in MapSource, where: s.id in ^ids),
            set: [next_fetch_at: now, updated_at: now]
          )

          Repo.update!(Changeset.change(batch, status: :processing))

          Repo.query!(
            "INSERT INTO import_windows (user_id, scheduled_at) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET scheduled_at = EXCLUDED.scheduled_at",
            [map.user_id, DateTime.to_naive(now)]
          )
        end

        {:ok, retried} =
          Oban.retry_all_jobs(from j in jobs, where: j.state in ["scheduled", "retryable"])

        inserted =
          Enum.map(new_sources, &ImportJob.new(%{"source_id" => &1.id})) |> Oban.insert_all()

        {:ok, length(inserted) + retried}
      end)
    else
      false -> {:error, :disabled}
      _ -> {:error, :not_found}
    end
  end

  @doc "Stops further processing for an owned import batch. Already imported points remain."
  @spec cancel_batch(Scope.t() | nil, term(), term()) :: {:ok, ImportBatch.t()} | {:error, term()}
  def cancel_batch(scope, map_id, batch_id) do
    with %UserMap{} = map <- get_map(scope, map_id),
         {:ok, id} <- Ecto.Type.cast(:id, batch_id),
         %ImportBatch{} = batch <- Repo.get_by(ImportBatch, id: id, map_id: map.id) do
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [map.user_id])

        source_ids = Repo.all(from s in MapSource, where: s.import_batch_id == ^id, select: s.id)

        cancel_source_jobs(source_ids)

        Repo.update_all(
          from(s in MapSource,
            where: s.import_batch_id == ^id and s.status in [:pending, :processing, :failed]
          ),
          set: [status: :skipped, error_code: "cancelled", error_message: "Import cancelled."]
        )

        Repo.update(Changeset.change(batch, status: :cancelled))
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Updates batch progress from its source records."
  @spec refresh_batch(integer() | nil) :: :ok
  def refresh_batch(batch_id) do
    if batch_id do
      batch = Repo.get(ImportBatch, batch_id)

      if batch && batch.status != :cancelled do
        counts =
          Repo.all(
            from s in MapSource,
              where: s.import_batch_id == ^batch_id,
              group_by: s.status,
              select: {s.status, count(s.id)}
          )
          |> Map.new()

        success = Map.get(counts, :fetched, 0)
        failed = Map.get(counts, :failed, 0) + Map.get(counts, :skipped, 0)

        status =
          cond do
            success + failed < batch.total_count -> :processing
            failed > 0 -> :completed_with_errors
            true -> :completed
          end

        Repo.update_all(
          from(b in ImportBatch, where: b.id == ^batch_id and b.status != :cancelled),
          set: [
            processed_count: success + failed,
            success_count: success,
            failed_count: failed,
            status: status
          ]
        )
      end
    end

    :ok
  end

  @doc "Reports whether a meetup has finished using its Campfire end time. Unknown end times remain visible."
  @spec meetup_ended?(map(), DateTime.t()) :: boolean()
  def meetup_ended?(point, now \\ DateTime.utc_now()) do
    case point.ends_at do
      %DateTime{} = ends_at -> DateTime.compare(ends_at, now) != :gt
      _ -> false
    end
  end

  @doc "Returns only map points whose Campfire end time has not passed."
  @spec active_points([map()], DateTime.t()) :: [map()]
  def active_points(points, now \\ DateTime.utc_now()),
    do: Enum.reject(points, &meetup_ended?(&1, now))

  @doc "Returns only safe marker metadata. Owner views may include source links."
  @spec point_data(UserMap.t(), boolean()) :: [map()]
  def point_data(map, owner? \\ false) do
    now = DateTime.utc_now()

    images =
      CATools.Maps.ImageCache.local_urls(
        Enum.flat_map(map.points, &[&1.cover_photo_url, &1.host_avatar_url])
      )

    map.points
    |> Enum.sort_by(fn point ->
      case point.starts_at do
        nil ->
          {2, 0, point.id}

        starts_at ->
          if DateTime.compare(starts_at, now) == :lt do
            {1, -DateTime.to_unix(starts_at), point.id}
          else
            {0, DateTime.to_unix(starts_at), point.id}
          end
      end
    end)
    |> Enum.map(fn %MapPoint{} = point ->
      data =
        Map.take(point, [
          :id,
          :title,
          :group_name,
          :host_name,
          :description,
          :latitude,
          :longitude,
          :address,
          :starts_at,
          :ends_at
        ])

      data =
        data
        |> Map.put(:cover_photo_url, Map.get(images, point.cover_photo_url))
        |> Map.put(:host_avatar_url, Map.get(images, point.host_avatar_url))

      if owner?, do: Map.put(data, :source_url, point.source_url), else: data
    end)
  end

  defp cancel_source_jobs(source_ids) do
    Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "CATools.Campfire.ImportJob" and
            j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("(?->>'source_id')::bigint", j.args) in ^source_ids,
        select: j.id
    )
    |> Enum.each(&Oban.cancel_job/1)
  end

  defp validate_source_urls(changeset) do
    input = Changeset.get_field(changeset, :source_urls_input)

    case normalize_source_urls(input) do
      {:ok, _normalized_urls} ->
        changeset

      {:error, messages} ->
        Enum.reduce(messages, changeset, fn message, current_changeset ->
          Changeset.add_error(current_changeset, :source_urls_input, message)
        end)
    end
  end

  defp validate_source_url_lines(lines) do
    case lines do
      [] ->
        {:error, ["Enter at least one Campfire link."]}

      lines when length(lines) > 10_000 ->
        {:error, ["A map import can contain at most 10,000 links."]}

      _ ->
        {normalized_urls, errors, _seen_urls} =
          lines
          |> Enum.with_index(1)
          |> Enum.reduce({[], [], MapSet.new()}, fn {line, line_number},
                                                    {urls, messages, seen_urls} ->
            case normalize_source_url(line) do
              {:ok, normalized_url} ->
                case MapSet.member?(seen_urls, normalized_url) do
                  true ->
                    {urls, messages, seen_urls}

                  false ->
                    {[normalized_url | urls], messages, MapSet.put(seen_urls, normalized_url)}
                end

              {:error, message} ->
                {urls, messages ++ ["Line #{line_number}: #{message}"], seen_urls}
            end
          end)

        case {length(normalized_urls), errors} do
          {0, []} ->
            {:error, ["Enter at least one Campfire link."]}

          {_count, [_ | _] = messages} ->
            {:error, messages}

          {_count, []} ->
            {:ok, Enum.reverse(normalized_urls)}
        end
    end
  end

  defp normalize_source_url(url) do
    LinkResolver.normalize_source_url(url)
  end

  defp create_map_with_sources(changeset, normalized_urls) do
    slug = maybe_generate_public_slug(Changeset.get_field(changeset, :visibility))
    now = DateTime.utc_now(:second)

    final_changeset =
      changeset
      |> Changeset.put_change(:public_slug, slug)
      |> Changeset.put_change(:sources_count, length(normalized_urls))
      |> Changeset.put_change(:points_count, 0)

    source_entries =
      Enum.map(normalized_urls, fn url ->
        %{
          original_url: url,
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.transact(fn ->
      case Repo.insert(final_changeset) do
        {:ok, map} ->
          {:ok, batch} =
            Repo.insert(
              Changeset.change(%ImportBatch{},
                user_id: map.user_id,
                map_id: map.id,
                total_count: length(source_entries)
              )
            )

          inserted_sources =
            Enum.map(source_entries, fn entry ->
              Map.merge(entry, %{map_id: map.id, import_batch_id: batch.id})
            end)

          case Repo.insert_all(MapSource, inserted_sources) do
            {count, _} when count == length(inserted_sources) ->
              %{"user_id" => map.user_id} |> BatchScheduler.new() |> Oban.insert!()
              {:ok, Repo.preload(map, [:sources, :batches])}

            other ->
              Repo.rollback({:sources, other})
          end

        {:error, %Changeset{} = insert_changeset} ->
          Repo.rollback({:map, insert_changeset})
      end
    end)
    |> case do
      {:ok, map} ->
        {:ok, map}

      {:error, {:map, %Changeset{} = insert_changeset}} ->
        {:error, insert_changeset}

      {:error, {:sources, _reason}} ->
        {:error,
         Changeset.add_error(changeset, :source_urls_input, "Could not save map sources.")}
    end
  end

  defp maybe_generate_public_slug(visibility) do
    case visibility do
      :public -> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      _ -> nil
    end
  end

  defp authorized_user_id(scope) do
    case scope do
      %Scope{user: %{id: user_id}} -> {:ok, user_id}
      _ -> :error
    end
  end
end
