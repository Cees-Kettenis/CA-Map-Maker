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

    :ok
  end
end
