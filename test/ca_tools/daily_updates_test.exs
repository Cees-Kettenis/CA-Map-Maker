defmodule CATools.DailyUpdatesTest do
  use CATools.DataCase, async: true
  use Oban.Testing, repo: CATools.Repo
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.{Maps, Repo}
  alias CATools.Campfire.{ImportJob, MaintenanceJob}
  import Ecto.Query

  test "daily maintenance refreshes due future links once and leaves fresh and ended events alone" do
    scope = user_scope_fixture()
    map = map_fixture(scope)
    [due, ended] = map.sources
    old = DateTime.add(DateTime.utc_now(:second), -86_401)

    Repo.update_all(from(s in Maps.MapSource, where: s.map_id == ^map.id),
      set: [status: :fetched, last_fetched_at: old, updated_at: old]
    )

    Repo.insert!(%Maps.MapPoint{
      map_id: map.id,
      map_source_id: ended.id,
      title: "Ended",
      latitude: 3.0,
      longitude: 101.0,
      ends_at: DateTime.add(DateTime.utc_now(:second), -1)
    })

    fresh = map_fixture(scope)

    Repo.update_all(from(s in Maps.MapSource, where: s.map_id == ^fresh.id),
      set: [status: :fetched, last_fetched_at: DateTime.utc_now(:second)]
    )

    assert :ok = perform_job(MaintenanceJob, %{})
    assert Repo.get!(Maps.MapSource, due.id).status == :pending
    assert Repo.get!(Maps.MapSource, ended.id).status == :fetched
    assert Enum.all?(Maps.get_map(scope, fresh.id).sources, &(&1.status == :fetched))
    count = Repo.aggregate(Maps.ImportBatch, :count)
    assert :ok = perform_job(MaintenanceJob, %{})
    assert Repo.aggregate(Maps.ImportBatch, :count) == count
  end

  test "manual updates wake scheduled imports and do not duplicate jobs" do
    scope = user_scope_fixture()
    map = map_fixture(scope)
    source = hd(map.sources)
    Oban.insert!(ImportJob.new(%{"source_id" => source.id}, schedule_in: 3600))
    assert :ok = Maps.request_update(scope, map.id)
    assert :ok = Maps.request_update(scope, map.id)

    jobs =
      Repo.all(
        from j in Oban.Job,
          where:
            j.worker == "CATools.Campfire.ImportJob" and
              fragment("(?->>'source_id')::bigint", j.args) == ^source.id
      )

    assert length(jobs) == 1
    assert hd(jobs).state == "available"
    assert Repo.get!(Maps.MapSource, source.id).next_fetch_at
    assert {:error, :not_found} = Maps.request_update(user_scope_fixture(), map.id)
  end

  test "a recent failed attempt waits a day even if the last success is old" do
    scope = user_scope_fixture()
    map = map_fixture(scope)

    Repo.update_all(from(s in Maps.MapSource, where: s.map_id == ^map.id),
      set: [
        status: :failed,
        last_fetched_at: DateTime.add(DateTime.utc_now(:second), -172_800),
        updated_at: DateTime.utc_now(:second)
      ]
    )

    assert :ok = perform_job(MaintenanceJob, %{})
    assert Enum.all?(Maps.get_map(scope, map.id).sources, &(&1.status == :failed))
  end
end
