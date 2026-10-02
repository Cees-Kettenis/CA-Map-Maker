defmodule CATools.Maps do
  @moduledoc """
  The Maps context.
  """

  import Ecto.Query, warn: false

  alias CATools.Accounts.Scope
  alias CATools.Campfire.{BatchScheduler, LinkResolver}
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
        |> preload([:sources, :batches])
        |> Repo.all()

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
      {{:ok, user_id}, {:ok, map_id}} ->
        UserMap
        |> where([map], map.id == ^map_id and map.user_id == ^user_id)
        |> preload([:sources, :points, :batches])
        |> Repo.one()

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
        preload: [:points]
    )
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
  end

  @doc "Deletes an owned map, its sources, batches and points."
  @spec delete_map(Scope.t() | nil, term()) :: {:ok, UserMap.t()} | {:error, term()}
  def delete_map(scope, id) do
    case get_map(scope, id) do
      nil -> {:error, :not_found}
      map -> Repo.delete(map)
    end
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
                from s in candidates,
                  where: s.last_fetched_at < ^cutoff or is_nil(s.last_fetched_at)

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

  @doc "Returns only safe marker metadata. Owner views may include source links."
  @spec point_data(UserMap.t(), boolean()) :: [map()]
  def point_data(map, owner? \\ false) do
    Enum.map(map.points, fn %MapPoint{} = point ->
      data =
        Map.take(point, [
          :id,
          :title,
          :group_name,
          :description,
          :latitude,
          :longitude,
          :address,
          :starts_at,
          :ends_at
        ])

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
