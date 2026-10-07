defmodule CATools.Campfire.MaintenanceJob do
  @moduledoc "Recovers unscheduled legacy links and ensures pending imports have a scheduler."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query
  alias CATools.Campfire.BatchScheduler
  alias CATools.Maps.{ImportBatch, MapSource, UserMap}
  alias CATools.Repo

  @impl Oban.Worker
  @doc "Attaches legacy pending sources to batches and queues unique schedulers."
  @spec perform(Oban.Job.t()) :: :ok
  def perform(_job) do
    users =
      Repo.all(
        from s in MapSource,
          join: m in UserMap,
          on: m.id == s.map_id,
          where: s.status == :pending,
          select: m.user_id,
          distinct: true
      )

    Enum.each(users, fn user_id ->
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [user_id])

        legacy =
          Repo.all(
            from s in MapSource,
              join: m in UserMap,
              on: m.id == s.map_id,
              where: m.user_id == ^user_id and s.status == :pending and is_nil(s.import_batch_id),
              select: {s.id, s.map_id}
          )

        Enum.each(Enum.group_by(legacy, &elem(&1, 1), &elem(&1, 0)), fn {map_id, ids} ->
          batch =
            Repo.insert!(
              Ecto.Changeset.change(%ImportBatch{},
                user_id: user_id,
                map_id: map_id,
                total_count: length(ids)
              )
            )

          Repo.update_all(from(s in MapSource, where: s.id in ^ids),
            set: [import_batch_id: batch.id, next_fetch_at: nil]
          )
        end)

        %{"user_id" => user_id} |> BatchScheduler.new() |> Oban.insert!()
        {:ok, :queued}
      end)
    end)

    now = DateTime.utc_now(:second)

    cache_cutoff = DateTime.add(now, -7 * 86_400, :second)

    Repo.delete_all(
      from cache in CATools.Campfire.ResponseCache, where: cache.fetched_at < ^cache_cutoff
    )

    Repo.all(
      from c in CATools.Communities.Community,
        where:
          c.enabled and not is_nil(c.map_id) and
            (is_nil(c.next_check_at) or c.next_check_at <= ^now),
        select: c.id
    )
    |> Enum.each(fn id ->
      Oban.insert!(CATools.Campfire.CommunitySyncJob.new(%{"community_id" => id}))
    end)

    cutoff = DateTime.add(now, -86_400, :second)

    Repo.all(
      from m in UserMap,
        join: s in MapSource,
        on: s.map_id == m.id,
        left_join: c in CATools.Communities.Community,
        on: c.map_id == m.id,
        left_join: p in CATools.Maps.MapPoint,
        on: p.map_source_id == s.id,
        where:
          is_nil(m.meetup_date) and (is_nil(c.id) or c.enabled) and
            s.status in [:fetched, :failed, :skipped] and
            fragment("GREATEST(?, ?)", s.last_fetched_at, s.updated_at) <= ^cutoff and
            (is_nil(p.ends_at) or p.ends_at > ^now),
        distinct: true,
        preload: [:user]
    )
    |> Enum.each(fn map ->
      CATools.Maps.refresh_map(CATools.Accounts.Scope.for_user(map.user), map.id, :stale)
    end)

    :ok
  end
end
