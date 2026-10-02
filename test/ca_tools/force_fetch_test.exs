defmodule CATools.ForceFetchTest do
  use CATools.DataCase, async: false
  use Oban.Testing, repo: CATools.Repo
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.{Maps, Repo}
  alias CATools.Campfire.{BatchScheduler, ImportJob}
  alias CATools.Maps.{ImportBatch, MapSource}

  test "forces only the selected batch despite an active scheduling window and prevents duplicates" do
    scope = user_scope_fixture()

    first =
      map_fixture(scope, %{
        "source_urls_input" => Enum.map_join(1..60, "\n", &"https://cmpf.re/force#{&1}")
      })

    other = map_fixture(scope, %{"source_urls_input" => "https://cmpf.re/other"})

    Repo.query!("INSERT INTO import_windows (user_id, scheduled_at) VALUES ($1, $2)", [
      scope.user.id,
      DateTime.utc_now(:second) |> DateTime.to_naive()
    ])

    batch = hd(first.batches)
    assert :ok = perform_job(BatchScheduler, %{user_id: scope.user.id})
    assert all_enqueued(worker: ImportJob) == []
    assert {:ok, 60} = Maps.force_fetch_batch(scope, first.id, batch.id)
    assert length(all_enqueued(worker: ImportJob)) == 60
    assert Repo.get!(ImportBatch, batch.id).status == :processing
    assert Repo.get!(MapSource, hd(other.sources).id).next_fetch_at == nil
    assert {:ok, 0} = Maps.force_fetch_batch(scope, first.id, batch.id)
    assert length(all_enqueued(worker: ImportJob)) == 60
  end

  test "brings an existing scheduled import forward without inserting a duplicate" do
    scope = user_scope_fixture()
    map = map_fixture(scope, %{"source_urls_input" => "https://cmpf.re/scheduled"})
    source = hd(map.sources)
    future = DateTime.utc_now(:second) |> DateTime.add(600)
    Repo.update!(Ecto.Changeset.change(source, next_fetch_at: future))
    {:ok, job} = ImportJob.new(%{source_id: source.id}, scheduled_at: future) |> Oban.insert()
    assert {:ok, 1} = Maps.force_fetch_batch(scope, map.id, hd(map.batches).id)
    assert Repo.get!(Oban.Job, job.id).state == "available"
    assert length(all_enqueued(worker: ImportJob)) == 1
  end

  test "rejects another owner's batch and cancelled batches" do
    owner = user_scope_fixture()
    map = map_fixture(owner)
    batch = hd(map.batches)
    assert {:error, :not_found} = Maps.force_fetch_batch(user_scope_fixture(), map.id, batch.id)
    other_map = map_fixture(owner)
    assert {:error, :not_pending} = Maps.force_fetch_batch(owner, other_map.id, batch.id)
    {:ok, _} = Maps.cancel_batch(owner, map.id, batch.id)
    assert {:error, :not_pending} = Maps.force_fetch_batch(owner, map.id, batch.id)
    assert all_enqueued(worker: ImportJob) == []
  end

  test "temporary control is disabled when the feature flag is off" do
    original = Application.fetch_env!(:ca_tools, :temporary_force_fetch_enabled)
    Application.put_env(:ca_tools, :temporary_force_fetch_enabled, false)
    on_exit(fn -> Application.put_env(:ca_tools, :temporary_force_fetch_enabled, original) end)
    scope = user_scope_fixture()
    map = map_fixture(scope)
    refute Maps.force_fetch_enabled?()
    assert {:error, :disabled} = Maps.force_fetch_batch(scope, map.id, hd(map.batches).id)
    assert all_enqueued(worker: ImportJob) == []
  end
end
