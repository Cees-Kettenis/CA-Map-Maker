defmodule CATools.MeetupMapsTest do
  use CATools.DataCase, async: true
  import CATools.AccountsFixtures
  alias CATools.{Communities, Maps, MeetupMaps, Repo}
  alias CATools.Maps.{MapPoint, MapSource}

  test "bulk groups are independent, deduplicated, and invalid lists roll back" do
    scope = user_scope_fixture()

    links =
      "https://campfire.nianticlabs.com/discover/clubs/one\nhttps://campfire.nianticlabs.com/discover/clubs/two"

    assert {:ok, [one, two]} = Communities.add_links(scope, links <> "\n" <> links)
    refute one.map_id == two.map_id
    assert {:ok, _} = Communities.add_links(scope, links)
    assert length(Communities.list(scope)) == 2

    assert {:error, _} =
             Communities.add_links(
               scope,
               "https://campfire.nianticlabs.com/discover/clubs/three\nhttps://example.com/wrong"
             )

    assert length(Communities.list(scope)) == 2
    assert {:ok, _} = Communities.save(scope, %{enabled: false}, two.id)
    assert Communities.get(scope, one.id).enabled
    refute Communities.get(scope, two.id).enabled

    assert {:error, :not_found} =
             Communities.save(user_scope_fixture(), %{enabled: false}, two.id)

    assert {:ok, invitation} = Communities.invite(scope, %{email: "friend@example.com"}, two.id)
    assert Communities.get(scope, one.id).invitations == []
    assert [^invitation] = Communities.get(scope, two.id).invitations
  end

  test "date maps merge selected groups, deduplicate events and respect local midnight" do
    scope = user_scope_fixture()

    {:ok, [one, two, three]} =
      Communities.add_links(
        scope,
        Enum.map_join(
          ["one", "two", "three"],
          "\n",
          &"https://campfire.nianticlabs.com/discover/clubs/#{&1}"
        )
      )

    add_point(one, "early", ~U[2026-10-02 15:59:59Z])
    add_point(one, "start", ~U[2026-10-02 16:00:00Z])
    add_point(one, "end", ~U[2026-10-03 15:59:59Z])
    add_point(two, "start", ~U[2026-10-02 16:00:00Z])
    add_point(two, "late", ~U[2026-10-03 16:00:00Z])
    add_point(three, "unselected", ~U[2026-10-03 08:00:00Z])

    assert {:ok, map} =
             MeetupMaps.create(scope, %{
               name: "Saturday",
               meetup_date: "2026-10-03",
               utc_offset_minutes: 480,
               community_ids: [one.id, two.id]
             })

    assert Enum.sort(Enum.map(map.points, & &1.campfire_id)) == ["end", "start"]
    assert map.visibility == :private
    assert map.points_count == 2
    assert map.sources_count == 2
    assert Repo.aggregate(Ecto.Query.from(p in MapPoint, where: p.map_id == ^map.id), :count) == 0

    assert Repo.aggregate(Ecto.Query.from(s in MapSource, where: s.map_id == ^map.id), :count) ==
             0

    assert Enum.all?(map.points, &(&1.map_id in [one.map_id, two.map_id]))
    assert Enum.map(MeetupMaps.communities(scope, map.id), & &1.id) == [one.id, two.id]
    assert MeetupMaps.communities(user_scope_fixture(), map.id) == []
    assert Maps.get_map(user_scope_fixture(), map.id) == nil
  end

  test "linked maps read changes directly without rebuilding or copying events" do
    scope = user_scope_fixture()

    {:ok, [community]} =
      Communities.add_links(scope, "https://campfire.nianticlabs.com/discover/clubs/one")

    assert {:ok, map} =
             MeetupMaps.create(scope, %{
               name: "Meetups",
               meetup_date: "2026-10-03",
               utc_offset_minutes: 0,
               community_ids: [community.id]
             })

    assert map.points == []
    original = add_point(community, "event", ~U[2026-10-03 12:00:00Z])
    [copied] = Maps.get_map(scope, map.id).points

    Repo.update!(
      Ecto.Changeset.change(original,
        title: "New title",
        host_name: "Updated host",
        cover_photo_url: "https://cdn.example.com/new.png"
      )
    )

    [updated] = Maps.get_map(scope, map.id).points
    assert updated.id == copied.id
    assert updated.title == "New title"
    assert updated.host_name == "Updated host"
    assert updated.cover_photo_url == "https://cdn.example.com/new.png"
    Repo.update!(Ecto.Changeset.change(original, starts_at: ~U[2026-10-04 12:00:00Z]))
    empty = Maps.get_map(scope, map.id)
    assert empty.points == []
    assert empty.sources == []
    assert empty.points_count == 0
  end

  test "date map validation rejects foreign groups, missing dates and invalid offsets" do
    owner = user_scope_fixture()

    {:ok, [community]} =
      Communities.add_links(owner, "https://campfire.nianticlabs.com/discover/clubs/one")

    attrs = %{
      name: "Map",
      meetup_date: "2026-10-03",
      utc_offset_minutes: 0,
      community_ids: [community.id]
    }

    assert {:error, changeset} = MeetupMaps.create(user_scope_fixture(), attrs)
    assert errors_on(changeset).community_ids != []

    for bad <- [
          %{meetup_date: "invalid"},
          %{utc_offset_minutes: 900},
          %{community_ids: nil},
          %{community_ids: []}
        ] do
      assert {:error, %Ecto.Changeset{}} = MeetupMaps.create(owner, Map.merge(attrs, bad))
    end
  end

  test "deleting a group removes its invitations and only its events from linked maps" do
    scope = user_scope_fixture()

    {:ok, [one, two]} =
      Communities.add_links(
        scope,
        "https://campfire.nianticlabs.com/discover/clubs/one\nhttps://campfire.nianticlabs.com/discover/clubs/two"
      )

    add_point(one, "one-event", ~U[2026-10-03 12:00:00Z])
    add_point(two, "two-event", ~U[2026-10-03 12:00:00Z])
    {:ok, invitation} = Communities.invite(scope, %{email: "friend@example.com"}, one.id)

    {:ok, map} =
      MeetupMaps.create(scope, %{
        name: "Both groups",
        meetup_date: "2026-10-03",
        community_ids: [one.id, two.id]
      })

    assert length(map.points) == 2
    assert {:error, :not_found} = Communities.delete(user_scope_fixture(), one.id)
    assert {:ok, _} = Maps.delete_map(scope, one.map_id)
    assert Communities.get(scope, one.id) == nil
    assert Repo.get(CATools.Communities.Invitation, invitation.id) == nil
    assert Enum.map(Maps.get_map(scope, map.id).points, & &1.campfire_id) == ["two-event"]
    assert {:ok, _} = Communities.delete(scope, two.id)
    assert Communities.list(scope) == []
    assert Maps.get_map(scope, map.id).points == []
    assert Maps.get_map(scope, map.id).points_count == 0
  end

  test "deleting a linked date map preserves its community and shared event records" do
    scope = user_scope_fixture()

    {:ok, [community]} =
      Communities.add_links(scope, "https://campfire.nianticlabs.com/discover/clubs/shared")

    point = add_point(community, "shared-event", ~U[2026-10-03 12:00:00Z])

    {:ok, map} =
      MeetupMaps.create(scope, %{
        name: "One day",
        meetup_date: "2026-10-03",
        community_ids: [community.id]
      })

    assert [shared] = map.points
    assert shared.id == point.id
    assert {:ok, _} = Maps.delete_map(scope, map.id)
    assert Repo.get(MapPoint, point.id)
    assert Repo.get(MapSource, point.map_source_id)
    assert Communities.get(scope, community.id)
  end

  defp add_point(community, id, starts_at) do
    url = "https://campfire.nianticlabs.com/discover/meetup/#{id}"

    source =
      Repo.insert!(%MapSource{
        map_id: community.map_id,
        original_url: url,
        status: :fetched,
        campfire_id: id
      })

    Repo.insert!(%MapPoint{
      map_id: community.map_id,
      map_source_id: source.id,
      source_url: url,
      campfire_id: id,
      title: id,
      starts_at: starts_at,
      latitude: 3.0,
      longitude: 101.0
    })
  end
end
