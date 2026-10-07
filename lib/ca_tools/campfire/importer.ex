defmodule CATools.Campfire.Importer do
  @moduledoc """
  Imports a single Campfire source into the local map and point tables.
  """

  import Ecto.Query, warn: false

  alias CATools.Campfire.{DataNormalizer, GraphQLClient, LinkResolver}
  alias CATools.Maps.{MapPoint, MapSource, UserMap}
  alias CATools.Repo
  alias Ecto.Changeset

  @type import_result() :: {:ok, MapSource.t()} | {:error, term()}

  @doc """
  Processes one map source end to end: resolve, fetch, normalize, and upsert.
  """
  @spec import_source(pos_integer(), keyword()) :: import_result()
  def import_source(source_id, opts \\ []) do
    case load_source(source_id) do
      nil ->
        {:error, :not_found}

      %MapSource{status: :skipped, error_code: "cancelled"} = source ->
        {:ok, source}

      %MapSource{} = source ->
        source
        |> mark_processing()
        |> run_import(opts)
    end
  end

  @doc "Populates a newly tracked group from existing local community events without external requests."
  @spec copy_group_events(CATools.Communities.Community.t()) ::
          {:ok, :copied} | {:error, term()}
  def copy_group_events(community) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [community.user_id])

      if community.club_id do
        Repo.all(
          from p in MapPoint,
            join: c in CATools.Communities.Community,
            on: c.map_id == p.map_id,
            join: s in assoc(p, :source),
            where:
              c.club_id == ^community.club_id and c.map_id != ^community.map_id and
                s.status == :fetched,
            order_by: [desc: p.updated_at, asc: p.id],
            select: {p, s}
        )
        |> Enum.uniq_by(fn {point, _} -> point.campfire_id || point.source_url || point.id end)
        |> Enum.each(fn {point, source} ->
          attrs =
            Map.take(
              point,
              MapPoint.__schema__(:fields) --
                [:id, :map_id, :map_source_id, :inserted_at, :updated_at]
            )

          store_group_event(
            community.map_id,
            %{
              resolved_url: source.resolved_url || source.original_url,
              campfire_id: source.campfire_id
            },
            attrs,
            source.last_fetched_at || DateTime.utc_now(:second)
          )
        end)
      end

      {:ok, :copied}
    end)
  end

  defp load_source(source_id) do
    MapSource
    |> where([source], source.id == ^source_id)
    |> join(:inner, [source], map in assoc(source, :map))
    |> join(:inner, [_source, map], user in assoc(map, :user))
    |> preload([_source, map, user], [:point, map: {map, user: user}])
    |> Repo.one()
  end

  defp mark_processing(source) do
    attempt_count = (source.attempts || 0) + 1

    source
    |> Changeset.change(
      status: :processing,
      attempts: attempt_count,
      error_code: nil,
      error_message: nil
    )
    |> Repo.update()
  end

  defp run_import({:ok, source}, opts) do
    resolved =
      case {URI.parse(source.original_url).host,
            LinkResolver.extract_resource_from_url(source.original_url)} do
        {"campfire.nianticlabs.com", {:ok, resource}} ->
          {:ok, Map.put(resource, :resolved_url, source.original_url)}

        _ ->
          LinkResolver.resolve_source_url(source.original_url, opts)
      end

    with {:ok, resolved_source} <- resolved,
         {:ok, graphql_resource} <-
           GraphQLClient.fetch_resource(source.map.user, resolved_source, opts),
         {:ok, point_attrs} <-
           DataNormalizer.normalize_map_point(graphql_resource, resolved_source),
         {:ok, imported_source} <- persist_import(source, resolved_source, point_attrs) do
      CATools.Maps.ImageCache.enqueue([point_attrs.cover_photo_url, point_attrs.host_avatar_url])
      {:ok, imported_source}
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Changeset{} = changeset} ->
        case Keyword.has_key?(changeset.errors, :campfire_id) do
          true ->
            source
            |> Changeset.change(
              status: :skipped,
              error_code: "duplicate_event",
              error_message: "This event is already included in this map."
            )
            |> Repo.update()

          false ->
            fail_source(source, %{
              code: "invalid_data",
              message: "Campfire data could not be saved."
            })
        end

      {:error, :cancelled} ->
        {:ok, Repo.get!(MapSource, source.id)}

      {:error, %{} = error_details} ->
        fail_source(source, error_details)

      {:error, reason} ->
        fail_source(source, %{code: "import_failed", message: inspect(reason)})
    end
  end

  defp run_import({:error, %Changeset{} = changeset}, _opts) do
    {:error, changeset}
  end

  defp persist_import(source, resolved_source, point_attrs) do
    Repo.transact(fn ->
      origin = Repo.get_by(CATools.Communities.Community, map_id: source.map_id)

      shared_maps =
        if origin && origin.club_id && origin.club_id == point_attrs.club_id do
          Repo.all(
            from c in CATools.Communities.Community,
              where: c.club_id == ^origin.club_id and c.map_id != ^source.map_id,
              select: {c.user_id, c.map_id}
          )
        else
          []
        end

      [source.map.user_id | Enum.map(shared_maps, &elem(&1, 0))]
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [&1]))

      batch =
        if source.import_batch_id, do: Repo.get(CATools.Maps.ImportBatch, source.import_batch_id)

      if batch && batch.status == :cancelled, do: Repo.rollback(:cancelled)

      with {:ok, updated_source} <- update_source(source, resolved_source),
           {:ok, _point} <- upsert_point(source, point_attrs),
           {:ok, _map} <- refresh_map_counters(Repo, updated_source.map_id) do
        # Keep local account views available if another subscriber later removes the group.
        Enum.each(shared_maps, fn {_user_id, map_id} ->
          if Repo.exists?(
               from c in CATools.Communities.Community,
                 where: c.map_id == ^map_id and c.club_id == ^origin.club_id
             ) do
            store_group_event(
              map_id,
              resolved_source,
              point_attrs,
              updated_source.last_fetched_at
            )
          end
        end)

        {:ok, Repo.preload(updated_source, [:point, map: :user])}
      else
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %MapSource{} = imported_source} ->
        {:ok, imported_source}

      {:ok, {:ok, imported_source}} ->
        {:ok, imported_source}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_group_event(map_id, resolved_source, point_attrs, fetched_at) do
    existing =
      if point_attrs.campfire_id,
        do: Repo.get_by(MapSource, map_id: map_id, campfire_id: point_attrs.campfire_id)

    source =
      existing ||
        Repo.get_by(MapSource, map_id: map_id, original_url: resolved_source.resolved_url) ||
        %MapSource{map_id: map_id, original_url: resolved_source.resolved_url}

    source = Repo.preload(source, :point)
    {:ok, source} = update_source(source, resolved_source, fetched_at)
    {:ok, _point} = upsert_point(source, point_attrs)
    {:ok, _map} = refresh_map_counters(Repo, map_id)
    CATools.Maps.refresh_batch(source.import_batch_id)
  end

  defp update_source(source, resolved_source, fetched_at \\ DateTime.utc_now(:second)) do
    source
    |> Changeset.change(
      resolved_url: resolved_source.resolved_url,
      campfire_id: resolved_source.campfire_id,
      status: :fetched,
      error_code: nil,
      error_message: nil,
      last_fetched_at: fetched_at
    )
    |> Changeset.unique_constraint(:campfire_id, name: :map_sources_map_id_campfire_id_index)
    |> Repo.insert_or_update()
  end

  defp upsert_point(source, point_attrs) do
    case source.point do
      %MapPoint{} = point ->
        point
        |> Changeset.change(Map.merge(point_attrs, %{map_id: source.map_id}))
        |> Repo.update()

      _ ->
        %MapPoint{}
        |> Changeset.change(
          Map.merge(point_attrs, %{map_id: source.map_id, map_source_id: source.id})
        )
        |> Repo.insert()
    end
  end

  defp refresh_map_counters(repo, map_id) do
    points_count =
      MapPoint
      |> where([point], point.map_id == ^map_id)
      |> select([point], count(point.id))
      |> repo.one()

    map =
      UserMap
      |> where([map], map.id == ^map_id)
      |> repo.one()

    case map do
      %UserMap{} = loaded_map ->
        loaded_map
        |> Changeset.change(
          points_count: points_count,
          sources_count: repo.aggregate(from(s in MapSource, where: s.map_id == ^map_id), :count),
          last_imported_at: DateTime.utc_now(:second)
        )
        |> repo.update()

      nil ->
        {:error, :map_not_found}
    end
  end

  defp fail_source(source, error_details) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [source.map.user_id])
      current = Repo.get(MapSource, source.id)

      batch =
        if source.import_batch_id, do: Repo.get(CATools.Maps.ImportBatch, source.import_batch_id)

      cond do
        is_nil(current) ->
          {:error, :not_found}

        batch && batch.status == :cancelled ->
          {:ok, current}

        current.import_batch_id != source.import_batch_id ->
          {:ok, current}

        true ->
          current
          |> Changeset.change(
            status: :failed,
            error_code: error_details.code,
            error_message: error_details.message
          )
          |> Repo.update()
      end
    end)
  end
end
