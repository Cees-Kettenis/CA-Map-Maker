defmodule CATools.Campfire.CommunitySyncJob do
  @moduledoc "Discovers new group meetups once a day and queues the existing importer."
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
  def perform(%Oban.Job{args: %{"community_id" => id} = args} = job) do
    snapshot =
      Repo.transact(fn ->
        community = Repo.get(Community, id)

        if community do
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [community.user_id])
          community = Repo.get(Community, id)
          now = DateTime.utc_now(:second)

          if (community && community.enabled) and not is_nil(community.map_id) and
               (is_nil(community.next_check_at) or
                  DateTime.compare(community.next_check_at, now) != :gt) do
            community
            |> Changeset.change(next_check_at: DateTime.add(now, 86_400, :second))
            |> Repo.update!()
            |> Repo.preload(:user)
          end
        end
        |> then(&{:ok, &1})
      end)

    page_result =
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
                  CATools.Maps.ImageCache.enqueue([page.avatar_url])
                  now = DateTime.utc_now(:second)
                  map = Repo.get(UserMap, current.map_id)

                  if map do
                    urls =
                      Enum.map(
                        Enum.uniq(page.event_ids) -- Map.get(args, "seen_ids", []),
                        fn id ->
                          "https://campfire.nianticlabs.com/discover/meetup/" <>
                            URI.encode(id, &URI.char_unreserved?/1)
                        end
                      )

                    cutoff = DateTime.add(now, -86_400, :second)

                    stale_ids =
                      Repo.all(
                        from s in MapSource,
                          left_join: p in CATools.Maps.MapPoint,
                          on: p.map_source_id == s.id,
                          where:
                            (is_nil(p.ends_at) or p.ends_at > ^now) and
                              s.map_id == ^map.id and s.original_url in ^urls and
                              s.status == :fetched and
                              (^Map.get(args, "force", false) or is_nil(s.last_fetched_at) or
                                 s.last_fetched_at <= ^cutoff),
                          select: s.id
                      )

                    known =
                      Repo.all(
                        from s in MapSource, where: s.map_id == ^map.id, select: s.original_url
                      )
                      |> MapSet.new()

                    urls = Enum.reject(urls, &MapSet.member?(known, &1))

                    if urls != [] or stale_ids != [] do
                      batch =
                        Repo.insert!(
                          Changeset.change(%ImportBatch{},
                            user_id: current.user_id,
                            map_id: map.id,
                            total_count: length(urls) + length(stale_ids)
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

                      Repo.update_all(from(s in MapSource, where: s.id in ^stale_ids),
                        set: [
                          status: :pending,
                          import_batch_id: batch.id,
                          next_fetch_at: nil,
                          error_code: nil,
                          error_message: nil,
                          updated_at: now
                        ]
                      )

                      Repo.update!(
                        Changeset.change(map,
                          sources_count: map.sources_count + length(urls),
                          name: page.name
                        )
                      )

                      if Map.get(args, "force", false) or is_nil(current.last_checked_at) do
                        Repo.update_all(
                          from(s in MapSource, where: s.import_batch_id == ^batch.id),
                          set: [next_fetch_at: now]
                        )

                        pending =
                          Repo.all(from s in MapSource, where: s.import_batch_id == ^batch.id)

                        Enum.each(pending, fn s ->
                          Oban.insert!(CATools.Campfire.ImportJob.new(%{"source_id" => s.id}))
                        end)
                      else
                        Oban.insert!(BatchScheduler.new(%{"user_id" => current.user_id}))
                      end
                    else
                      Repo.update!(Changeset.change(map, name: page.name))
                    end

                    Repo.update!(
                      Changeset.change(current,
                        club_id: club_id,
                        name: page.name,
                        avatar_url: page.avatar_url,
                        cursor: page.next_cursor,
                        next_check_at:
                          if(page.next_cursor, do: now, else: DateTime.add(now, 86_400, :second)),
                        last_checked_at: now,
                        error_message: nil
                      )
                    )
                  end

                {:error, details} ->
                  Repo.update!(Changeset.change(current, error_message: details.message))
              end
            end

            {:ok, result}
          end)

        _ ->
          :ok
      end

    case Repo.get(Community, id) do
      %Community{cursor: cursor, enabled: true, next_check_at: next} = c
      when not is_nil(cursor) ->
        CATools.Maps.notify(c.user_id)

        seen_ids =
          case page_result do
            {:ok, {:ok, _, page}} -> page.event_ids ++ Map.get(args, "seen_ids", [])
            _ -> Map.get(args, "seen_ids", [])
          end

        continuation_args =
          args
          |> Map.put("seen_ids", Enum.uniq(seen_ids))
          |> Map.put("seen_cursors", [cursor | Map.get(args, "seen_cursors", [])])

        continuation_args =
          if match?({:ok, %Community{last_checked_at: nil}}, snapshot),
            do: Map.put(continuation_args, "force", true),
            else: continuation_args

        if cursor in Map.get(args, "seen_cursors", []) do
          Repo.update!(
            Changeset.change(c,
              cursor: nil,
              next_check_at: DateTime.add(DateTime.utc_now(:second), 86_400),
              error_message: "Campfire returned a repeated page cursor."
            )
          )
        else
          if next && DateTime.compare(next, DateTime.utc_now()) != :gt,
            do: perform(%{job | args: continuation_args})
        end

      %Community{} = c ->
        CATools.Maps.notify(c.user_id)

      _ ->
        :ok
    end

    :ok
  end
end
