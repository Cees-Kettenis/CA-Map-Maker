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

      %MapSource{} = source ->
        source
        |> mark_processing()
        |> run_import(opts)
    end
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
    with {:ok, resolved_source} <- LinkResolver.resolve_source_url(source.original_url, opts),
         {:ok, graphql_resource} <-
           GraphQLClient.fetch_resource(source.map.user, resolved_source, opts),
         {:ok, point_attrs} <-
           DataNormalizer.normalize_map_point(graphql_resource, resolved_source),
         {:ok, imported_source} <- persist_import(source, resolved_source, point_attrs) do
      {:ok, imported_source}
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %{} = error_details} ->
        fail_source(source, error_details)

      {:error, %Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        fail_source(source, %{code: "import_failed", message: inspect(reason)})
    end
  end

  defp run_import({:error, %Changeset{} = changeset}, _opts) do
    {:error, changeset}
  end

  defp persist_import(source, resolved_source, point_attrs) do
    Repo.transact(fn ->
      with {:ok, updated_source} <- update_source(source, resolved_source),
           {:ok, _point} <- upsert_point(source, point_attrs),
           {:ok, _map} <- refresh_map_counters(Repo, updated_source.map_id) do
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

  defp update_source(source, resolved_source) do
    source
    |> Changeset.change(
      resolved_url: resolved_source.resolved_url,
      campfire_id: resolved_source.campfire_id,
      status: :fetched,
      error_code: nil,
      error_message: nil,
      last_fetched_at: DateTime.utc_now(:second)
    )
    |> Repo.update()
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
          last_imported_at: DateTime.utc_now(:second)
        )
        |> repo.update()

      nil ->
        {:error, :map_not_found}
    end
  end

  defp fail_source(source, error_details) do
    source
    |> Changeset.change(
      status: :failed,
      error_code: error_details.code,
      error_message: error_details.message
    )
    |> Repo.update()
  end
end
