defmodule CATools.Campfire.BatchScheduler do
  @moduledoc "Schedules at most 50 links per user in each ten-minute window."
  use Oban.Worker,
    queue: :imports,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:user_id],
      states: [:available, :scheduled, :retryable]
    ]

  import Ecto.Query
  alias CATools.Campfire.ImportJob
  alias CATools.Maps.{ImportBatch, MapSource, UserMap}
  alias CATools.Repo

  @impl Oban.Worker
  @doc "Reserves a batch under a database lock and schedules the next window when needed."
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    now = DateTime.utc_now(:second)

    case Repo.transact(fn ->
           # Serialize scheduling across maps, nodes and concurrent requests for this owner.
           Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [user_id])

           %{rows: rows} =
             Repo.query!("SELECT scheduled_at FROM import_windows WHERE user_id = $1", [user_id])

           available_at =
             case rows do
               [[time]] -> time |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(600, :second)
               [] -> now
             end

           pending =
             from s in MapSource,
               join: m in UserMap,
               on: m.id == s.map_id,
               join: b in ImportBatch,
               on: b.id == s.import_batch_id,
               where: m.user_id == ^user_id and s.status == :pending and is_nil(s.next_fetch_at),
               where: b.status in [:queued, :processing],
               order_by: [asc: s.id]

           if DateTime.compare(now, available_at) != :lt do
             sources = Repo.all(from s in pending, limit: 50, lock: "FOR UPDATE")

             if sources != [] do
               ids = Enum.map(sources, & &1.id)
               batch_ids = Enum.uniq(Enum.map(sources, & &1.import_batch_id))

               Repo.update_all(from(s in MapSource, where: s.id in ^ids),
                 set: [next_fetch_at: now, updated_at: now]
               )

               Repo.update_all(from(b in ImportBatch, where: b.id in ^batch_ids),
                 set: [status: :processing, updated_at: now]
               )

               Repo.query!(
                 "INSERT INTO import_windows (user_id, scheduled_at) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET scheduled_at = EXCLUDED.scheduled_at",
                 [user_id, DateTime.to_naive(now)]
               )

               jobs = Enum.map(sources, &ImportJob.new(%{"source_id" => &1.id}))
               Oban.insert_all(jobs)
             end

             if Repo.exists?(pending) do
               %{"user_id" => user_id} |> new(schedule_in: 600) |> Oban.insert!()
             end
           else
             if Repo.exists?(pending) do
               %{"user_id" => user_id} |> new(scheduled_at: available_at) |> Oban.insert!()
             end
           end

           {:ok, :scheduled}
         end) do
      {:ok, :scheduled} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
