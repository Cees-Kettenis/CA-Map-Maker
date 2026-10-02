defmodule CATools.Campfire.BatchSchedulerTest do
  use CATools.DataCase, async: true
  use Oban.Testing, repo: CATools.Repo
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.Campfire.{BatchScheduler, ImportJob, MaintenanceJob}
  alias CATools.Maps
  alias CATools.Maps.{ImportBatch, MapSource}

  test "schedules only 50 links across maps for one user, persists the window and avoids duplicate jobs" do
    scope = user_scope_fixture()
    urls = Enum.map_join(1..70, "\n", &"https://cmpf.re/link#{&1}")
    first = map_fixture(scope, %{"source_urls_input" => urls})
    second = map_fixture(scope, %{"source_urls_input" => "https://cmpf.re/other"})
    # Simulate Oban executing the persisted scheduler so its unique successor can be scheduled.
    [scheduler] = all_enqueued(worker: BatchScheduler)
    Repo.update!(Ecto.Changeset.change(scheduler, state: "executing"))
    assert :ok = perform_job(BatchScheduler, %{"user_id" => scope.user.id})
    assert length(all_enqueued(worker: ImportJob)) == 50

    assert Repo.aggregate(
             from(s in MapSource, where: s.map_id == ^first.id and is_nil(s.next_fetch_at)),
             :count
           ) == 20

    assert Repo.get!(MapSource, hd(second.sources).id).next_fetch_at == nil
    assert [next] = all_enqueued(worker: BatchScheduler)
    assert DateTime.diff(next.scheduled_at, DateTime.utc_now()) in 598..600

    assert :ok = perform_job(BatchScheduler, %{"user_id" => scope.user.id})
    assert length(all_enqueued(worker: ImportJob)) == 50
    assert length(all_enqueued(worker: BatchScheduler)) == 1

    Repo.query!(
      "UPDATE import_windows SET scheduled_at = scheduled_at - INTERVAL '10 minutes' WHERE user_id = $1",
      [scope.user.id]
    )

    Repo.update!(Ecto.Changeset.change(next, state: "executing"))
    assert :ok = perform_job(BatchScheduler, %{"user_id" => scope.user.id})
    assert length(all_enqueued(worker: ImportJob)) == 71
  end

  test "different users receive independent windows" do
    for _ <- 1..2 do
      scope = user_scope_fixture()

      map_fixture(scope, %{
        "source_urls_input" => Enum.map_join(1..55, "\n", &"https://cmpf.re/link#{&1}")
      })

      assert :ok = perform_job(BatchScheduler, %{"user_id" => scope.user.id})
    end

    assert length(all_enqueued(worker: ImportJob)) == 100
  end

  test "10,000 links are stored without enqueuing 10,000 executable jobs" do
    scope = user_scope_fixture()

    map =
      map_fixture(scope, %{
        "source_urls_input" => Enum.map_join(1..10_000, "\n", &"https://cmpf.re/large#{&1}")
      })

    assert map.sources_count == 10_000
    assert length(map.sources) == 10_000
    assert hd(map.batches).total_count == 10_000
    assert length(all_enqueued(worker: BatchScheduler)) == 1
    assert all_enqueued(worker: ImportJob) == []
    assert :ok = perform_job(BatchScheduler, %{"user_id" => scope.user.id})
    assert length(all_enqueued(worker: ImportJob)) == 50

    assert Repo.aggregate(
             from(s in MapSource, where: s.map_id == ^map.id and is_nil(s.next_fetch_at)),
             :count
           ) == 9_950
  end

  test "cancelled batches stop scheduling and execution" do
    scope = user_scope_fixture()
    map = map_fixture(scope)
    [batch] = map.batches
    Repo.update!(Ecto.Changeset.change(hd(map.sources), status: :failed))
    assert {:ok, _} = Maps.cancel_batch(scope, map.id, batch.id)
    assert :ok = perform_job(BatchScheduler, %{"user_id" => scope.user.id})
    assert all_enqueued(worker: ImportJob) == []
    assert {:cancel, :skipped} = perform_job(ImportJob, %{"source_id" => hd(map.sources).id})
    assert Repo.get!(ImportBatch, batch.id).status == :cancelled
  end

  test "maintenance attaches legacy sources and queues their scheduler" do
    scope = user_scope_fixture()
    map = map_fixture(scope)
    Repo.update_all(from(s in MapSource, where: s.map_id == ^map.id), set: [import_batch_id: nil])
    assert :ok = perform_job(MaintenanceJob, %{})
    assert Repo.get!(MapSource, hd(map.sources).id).import_batch_id != nil
    assert length(all_enqueued(worker: BatchScheduler)) == 1
  end
end
