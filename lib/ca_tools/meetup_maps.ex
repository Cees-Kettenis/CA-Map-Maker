defmodule CATools.MeetupMaps do
  @moduledoc "Date-based maps assembled from the owner's tracked communities."
  import Ecto.Query
  alias CATools.Accounts.Scope
  alias CATools.Communities.Community
  alias CATools.Maps.{CommunitySelection, MapPoint, UserMap}
  alias CATools.Repo
  alias Ecto.Changeset

  @doc "Validates the date-map creation form without requiring pasted meetup links."
  @spec change(map()) :: Changeset.t()
  def change(attrs \\ %{}) do
    {%{},
     %{
       name: :string,
       meetup_date: :date,
       utc_offset_minutes: :integer,
       community_ids: {:array, :integer}
     }}
    |> Changeset.cast(attrs, [:name, :meetup_date, :utc_offset_minutes, :community_ids])
    |> Changeset.validate_required([:name, :meetup_date, :utc_offset_minutes, :community_ids])
    |> Changeset.validate_length(:name, max: 160)
    |> Changeset.validate_number(:utc_offset_minutes,
      greater_than_or_equal_to: -720,
      less_than_or_equal_to: 840
    )
  end

  @doc "Creates a private date map linked only to selected communities owned by this account."
  @spec create(Scope.t(), map()) :: {:ok, UserMap.t()} | {:error, term()}
  def create(scope, attrs) do
    changeset =
      change(
        Map.put_new(
          attrs,
          if(Map.has_key?(attrs, "name"), do: "utc_offset_minutes", else: :utc_offset_minutes),
          0
        )
      )

    ids = (Changeset.get_field(changeset, :community_ids, []) || []) |> Enum.uniq()

    communities =
      Repo.all(from c in Community, where: c.user_id == ^scope.user.id and c.id in ^ids)

    changeset =
      if length(communities) != length(ids) or ids == [],
        do: Changeset.add_error(changeset, :community_ids, "Choose your tracked communities."),
        else: changeset

    if changeset.valid? do
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])

        map =
          Repo.insert!(
            Changeset.change(
              %UserMap{user_id: scope.user.id, visibility: :private},
              Map.take(Changeset.apply_changes(changeset), [
                :name,
                :meetup_date,
                :utc_offset_minutes
              ])
            )
          )

        Enum.each(communities, fn c ->
          Repo.insert!(%CommunitySelection{map_id: map.id, community_id: c.id})
        end)

        {:ok, CATools.Maps.get_map(scope, map.id)}
      end)
      |> then(fn result ->
        case result do
          {:ok, map} ->
            CATools.Maps.request_update(scope, map.id)
            {:ok, CATools.Maps.get_map(scope, map.id)}

          error ->
            error
        end
      end)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc "Returns the tracked communities linked to an owned date map."
  @spec communities(Scope.t(), term()) :: [Community.t()]
  def communities(scope, map_id) do
    case CATools.Maps.get_map(scope, map_id) do
      nil ->
        []

      map ->
        Repo.all(
          from c in Community,
            join: s in CommunitySelection,
            on: s.community_id == c.id,
            where: s.map_id == ^map.id and c.user_id == ^scope.user.id,
            order_by: c.id
        )
    end
  end

  @doc "Saves an owned date map's community selection using only local records."
  @spec update_communities(Scope.t(), term(), term()) ::
          {:ok, UserMap.t()} | {:error, Changeset.t() | :not_found | :not_date_map}
  def update_communities(scope, map_id, community_ids) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])

      case CATools.Maps.get_map(scope, map_id) do
        nil ->
          {:error, :not_found}

        %UserMap{meetup_date: %Date{}} = map ->
          changeset =
            {%{}, %{community_ids: {:array, :integer}}}
            |> Changeset.cast(%{community_ids: community_ids}, [:community_ids])
            |> Changeset.validate_required([:community_ids])
            |> Changeset.validate_length(:community_ids, min: 1)

          ids = Enum.uniq(Changeset.get_field(changeset, :community_ids, []) || [])

          owned_ids =
            Repo.all(
              from c in Community,
                where: c.user_id == ^scope.user.id and c.id in ^ids and not is_nil(c.map_id),
                select: c.id
            )

          changeset =
            if length(owned_ids) == length(ids),
              do: changeset,
              else:
                Changeset.add_error(changeset, :community_ids, "Choose your tracked communities.")

          if changeset.valid? do
            Repo.delete_all(
              from s in CommunitySelection,
                where: s.map_id == ^map.id and s.community_id not in ^ids
            )

            Enum.each(ids, fn community_id ->
              Repo.insert!(%CommunitySelection{map_id: map.id, community_id: community_id},
                on_conflict: :nothing
              )
            end)

            {:ok, CATools.Maps.get_map(scope, map.id)}
          else
            {:error, %{changeset | action: :update}}
          end

        _ ->
          {:error, :not_date_map}
      end
    end)
    |> then(fn result ->
      if match?({:ok, _}, result), do: CATools.Maps.notify(scope.user.id)
      result
    end)
  end

  @doc "Loads shared community events for a date map without copying sources or points."
  @spec load_events(UserMap.t()) :: UserMap.t()
  def load_events(map) do
    case map.meetup_date do
      %Date{} ->
        start =
          DateTime.new!(map.meetup_date, ~T[00:00:00], "Etc/UTC")
          |> DateTime.add(-map.utc_offset_minutes * 60, :second)

        finish = DateTime.add(start, 86_400, :second)

        points =
          Repo.all(
            from p in MapPoint,
              join: c in Community,
              on: c.map_id == p.map_id,
              join: s in CommunitySelection,
              on: s.community_id == c.id,
              where:
                s.map_id == ^map.id and c.user_id == ^map.user_id and
                  p.starts_at >= ^start and p.starts_at < ^finish,
              order_by: [desc: p.updated_at, asc: p.id],
              preload: [:source]
          )
          |> Enum.uniq_by(&(&1.campfire_id || &1.source_url || &1.id))

        sources = Enum.map(points, & &1.source)
        dates = Enum.map(sources, & &1.last_fetched_at) |> Enum.reject(&is_nil/1)
        last = Enum.max_by(dates, &DateTime.to_unix/1, fn -> nil end)

        %{
          map
          | points: points,
            sources: sources,
            batches: [],
            points_count: length(points),
            sources_count: length(sources),
            last_imported_at: last
        }

      _ ->
        map
    end
  end
end
