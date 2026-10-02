defmodule CATools.Campfire.CommunitySyncJob do
  @moduledoc "Discovers new group meetups every ten minutes and queues the existing importer."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:community_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query
  alias CATools.Campfire.{ClubResolver, GraphQLClient, BatchScheduler}
  alias CATools.Communities.Community
  alias CATools.Maps.{ImportBatch, MapSource, UserMap}
  alias CATools.Repo
  alias Ecto.Changeset

  @impl Oban.Worker
  @doc "Checks a due community and imports previously unseen meetup links."
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"community_id" => id}}) do
    snapshot =
      Repo.transact(fn ->
        community = Repo.get(Community, id)

        if community do
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [community.user_id])
          community = Repo.get!(Community, id)
          now = DateTime.utc_now(:second)

          if community.enabled and not is_nil(community.map_id) and
               (is_nil(community.next_check_at) or
                  DateTime.compare(community.next_check_at, now) != :gt) do
            community
            |> Changeset.change(next_check_at: DateTime.add(now, 600, :second))
            |> Repo.update!()
            |> Repo.preload(:user)
          end
        end
        |> then(&{:ok, &1})
      end)

    case snapshot do
      {:ok, %Community{} = community} ->
        result =
          with {:ok, club_id} <-
                 if(community.club_id,
                   do: {:ok, community.club_id},
                   else: ClubResolver.resolve(community.source_url)
                 ),
               {:ok, page} <-
                 GraphQLClient.fetch_club_page(community.user, club_id, community.cursor) do
            {:ok, club_id, page}
          end

        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [community.user_id])
          current = Repo.get(Community, community.id)

          if current && current.enabled && current.map_id == community.map_id &&
               current.source_url == community.source_url do
            case result do
              {:ok, club_id, page} ->
                now = DateTime.utc_now(:second)
                map = Repo.get(UserMap, current.map_id)

                if map do
                  urls =
                    Enum.map(page.event_ids, fn id ->
                      "https://campfire.nianticlabs.com/discover/meetup/" <>
                        URI.encode(id, &URI.char_unreserved?/1)
                    end)

                  known =
                    Repo.all(
                      from s in MapSource, where: s.map_id == ^map.id, select: s.original_url
                    )
                    |> MapSet.new()

                  urls = Enum.reject(urls, &MapSet.member?(known, &1))

                  if urls != [] do
                    batch =
                      Repo.insert!(
                        Changeset.change(%ImportBatch{},
                          user_id: current.user_id,
                          map_id: map.id,
                          total_count: length(urls)
                        )
                      )

                    entries =
                      Enum.map(
                        urls,
                        &%{
                          map_id: map.id,
                          import_batch_id: batch.id,
                          original_url: &1,
                          status: :pending,
                          inserted_at: now,
                          updated_at: now
                        }
                      )

                    Repo.insert_all(MapSource, entries)

                    Repo.update!(
                      Changeset.change(map,
                        sources_count: map.sources_count + length(urls),
                        name: page.name
                      )
                    )

                    Oban.insert!(BatchScheduler.new(%{"user_id" => current.user_id}))
                  else
                    Repo.update!(Changeset.change(map, name: page.name))
                  end

                  Repo.update!(
                    Changeset.change(current,
                      club_id: club_id,
                      name: page.name,
                      cursor: page.next_cursor,
                      last_checked_at: now,
                      error_message: nil
                    )
                  )
                end

              {:error, details} ->
                Repo.update!(Changeset.change(current, error_message: details.message))
            end
          end

          {:ok, :checked}
        end)

      _ ->
        :ok
    end

    :ok
  end
end
