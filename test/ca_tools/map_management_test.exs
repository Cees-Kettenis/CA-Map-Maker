defmodule CATools.MapManagementTest do
  use CATools.DataCase, async: true
  use Oban.Testing, repo: CATools.Repo
  alias CATools.Maps
  alias CATools.Maps.MapSource
  import CATools.AccountsFixtures
  import CATools.MapsFixtures

  test "meetups are ordered by the next event, followed by past and undated events" do
    now = DateTime.utc_now(:second)

    point = fn id, starts_at ->
      %CATools.Maps.MapPoint{id: id, title: "Meetup #{id}", starts_at: starts_at}
    end

    map = %CATools.Maps.UserMap{
      points: [
        point.(1, DateTime.add(now, 3600)),
        point.(2, nil),
        point.(3, DateTime.add(now, -3600)),
        point.(4, DateTime.add(now, 600)),
        point.(5, DateTime.add(now, -600))
      ]
    }

    assert Enum.map(Maps.point_data(map), & &1.id) == [4, 1, 5, 3, 2]
  end

  test "CRUD operations are owner scoped and changing visibility disables public access" do
    owner = user_scope_fixture()
    other = user_scope_fixture()
    map = map_fixture(owner)
    assert {:error, :not_found} = Maps.update_map(other, map.id, %{"name" => "stolen"})
    assert {:error, :not_found} = Maps.delete_map(other, map.id)
    assert {:error, :not_found} = Maps.refresh_map(other, map.id)
    assert Maps.get_map(owner, "not-an-id") == nil

    assert {:ok, public} =
             Maps.update_map(owner, map.id, %{"visibility" => "public", "name" => "New name"})

    assert Maps.get_public_map(public.public_slug).name == "New name"
    assert {:ok, _} = Maps.update_map(owner, map.id, %{"visibility" => "private"})
    assert Maps.get_public_map(public.public_slug) == nil
    assert {:ok, _} = Maps.delete_map(owner, map.id)
    assert Repo.get(MapSource, hd(map.sources).id) == nil
  end

  test "refreshing failed links keeps fetched points and makes a new batch" do
    scope = user_scope_fixture()
    map = map_fixture(scope, %{"source_urls_input" => "https://cmpf.re/a\nhttps://cmpf.re/b"})
    [failed, fetched] = Enum.sort_by(map.sources, & &1.id)
    Repo.update!(Ecto.Changeset.change(failed, status: :failed))

    job =
      %{"source_id" => failed.id}
      |> CATools.Campfire.ImportJob.new()
      |> Oban.insert!()

    Repo.update!(Ecto.Changeset.change(job, state: "retryable"))

    Repo.update!(
      Ecto.Changeset.change(fetched, status: :fetched, last_fetched_at: DateTime.utc_now(:second))
    )

    assert {:ok, batch} = Maps.refresh_map(scope, map.id)
    assert batch.total_count == 1
    assert Repo.get!(MapSource, failed.id).status == :pending
    assert Repo.get!(MapSource, fetched.id).status == :fetched
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    assert {:error, :no_sources} = Maps.refresh_map(scope, map.id, :stale)
  end

  test "imports over 10,000 links are rejected" do
    links = Enum.map_join(1..10_001, "\n", &"https://cmpf.re/#{&1}")

    assert {:error, ["A map import can contain at most 10,000 links."]} =
             Maps.normalize_source_urls(links)
  end

  test "batch cancellation cannot affect another owner's map" do
    scope = user_scope_fixture()
    map = map_fixture(scope)

    assert {:error, :not_found} =
             Maps.cancel_batch(user_scope_fixture(), map.id, hd(map.batches).id)

    assert Repo.get!(MapSource, hd(map.sources).id).status == :pending
  end
end
