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

  test "finding meetups reuses selected groups' cached events but excludes other accounts' private maps" do
    scope = user_scope_fixture()
    stranger = user_scope_fixture()

    {:ok, [community]} =
      Communities.add_links(scope, "https://campfire.nianticlabs.com/discover/clubs/selected")

    community = Repo.update!(Ecto.Changeset.change(community, club_id: "selected-club"))

    {:ok, map} =
      MeetupMaps.create(scope, %{
        name: "Saturday",
        meetup_date: "2099-10-03",
        utc_offset_minutes: 480,
        community_ids: [community.id]
      })

    pasted = CATools.MapsFixtures.map_fixture(scope)
    foreign = CATools.MapsFixtures.map_fixture(stranger)

    local = add_point(%{map_id: pasted.id}, "late-local", ~U[2099-10-02 16:00:00Z])
    Repo.update!(Ecto.Changeset.change(local, club_id: community.club_id))
    outside = add_point(%{map_id: pasted.id}, "next-day", ~U[2099-10-03 16:00:00Z])
    Repo.update!(Ecto.Changeset.change(outside, club_id: community.club_id))
    other = add_point(%{map_id: pasted.id}, "other-club", ~U[2099-10-03 12:00:00Z])
    Repo.update!(Ecto.Changeset.change(other, club_id: "other-club"))
    private = add_point(%{map_id: foreign.id}, "foreign-event", ~U[2099-10-03 12:00:00Z])
    Repo.update!(Ecto.Changeset.change(private, club_id: community.club_id))

    {:ok, [cached_group]} =
      Communities.add_links(stranger, "https://campfire.nianticlabs.com/discover/clubs/selected")

    cached_group = Repo.update!(Ecto.Changeset.change(cached_group, club_id: community.club_id))
    cached = add_point(cached_group, "shared-cache", ~U[2099-10-03 05:30:00Z])
    Repo.update!(Ecto.Changeset.change(cached, club_id: community.club_id))
    jobs = Repo.all(Oban.Job)

    assert {:ok, found} = MeetupMaps.update_communities(scope, map.id, [community.id])
    assert Enum.sort(Enum.map(found.points, & &1.id)) == [local.id, cached.id]
    assert Repo.get!(MapPoint, local.id).map_id == pasted.id
    assert Repo.all(Oban.Job) == jobs
    assert {:ok, public} = Maps.update_map(scope, map.id, %{visibility: :public})

    assert Enum.sort(Enum.map(Maps.get_public_map(public.public_slug).points, & &1.id)) ==
             [local.id, cached.id]

    cached_source = Repo.get!(MapSource, cached.map_source_id)
    assert :ok = Maps.request_update(scope, map.id)
    assert Repo.get!(MapSource, cached.map_source_id) == cached_source
    refute Enum.any?(Repo.all(Oban.Job), &(&1.args["source_id"] == cached.map_source_id))
  end

  test "changing communities validates ownership and preserves the map and shared records" do
    owner = user_scope_fixture()
    stranger = user_scope_fixture()

    {:ok, [one, two]} =
      Communities.add_links(
        owner,
        "https://campfire.nianticlabs.com/discover/clubs/one\nhttps://campfire.nianticlabs.com/discover/clubs/two"
      )

    {:ok, [foreign]} =
      Communities.add_links(stranger, "https://campfire.nianticlabs.com/discover/clubs/foreign")

    first = add_point(one, "first", ~U[2099-10-03 12:00:00Z])
    second = add_point(two, "second", ~U[2099-10-03 12:00:00Z])

    {:ok, map} =
      MeetupMaps.create(owner, %{
        name: "Saved date",
        meetup_date: "2099-10-03",
        utc_offset_minutes: 480,
        community_ids: [one.id]
      })

    {:ok, map} = Maps.update_map(owner, map.id, %{visibility: :public, description: "Keep this"})
    jobs = Repo.all(Oban.Job)

    assert {:error, :not_found} = MeetupMaps.update_communities(stranger, map.id, [foreign.id])
    assert {:error, :not_date_map} = MeetupMaps.update_communities(owner, one.map_id, [two.id])

    for invalid <- [[foreign.id], [two.id, foreign.id], [], nil, ["bad"], "bad", [-1]] do
      assert {:error, %Ecto.Changeset{}} = MeetupMaps.update_communities(owner, map.id, invalid)
      assert Enum.map(MeetupMaps.communities(owner, map.id), & &1.id) == [one.id]
    end

    assert {:ok, updated} =
             MeetupMaps.update_communities(owner, map.id, ["#{two.id}", "#{two.id}"])

    assert Enum.map(MeetupMaps.communities(owner, map.id), & &1.id) == [two.id]
    assert Enum.map(updated.points, & &1.id) == [second.id]
    assert updated.meetup_date == map.meetup_date
    assert updated.utc_offset_minutes == map.utc_offset_minutes
    assert updated.name == map.name
    assert updated.description == map.description
    assert updated.visibility == map.visibility
    assert updated.public_slug == map.public_slug
    assert Enum.map(Maps.get_public_map(map.public_slug).points, & &1.id) == [second.id]
    assert Repo.get!(MapPoint, first.id).map_id == one.map_id
    assert Repo.get!(MapPoint, second.id).map_id == two.map_id
    assert Repo.all(Oban.Job) == jobs
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

  test "meetups without covers reuse their own community's cached logo on group and date maps" do
    scope = user_scope_fixture()
    nonce = System.unique_integer([:positive])

    {:ok, communities} =
      Communities.add_links(
        scope,
        Enum.map_join(
          ["one", "two"],
          "\n",
          &"https://campfire.nianticlabs.com/discover/clubs/logo-#{&1}-#{nonce}"
        )
      )

    logos =
      Enum.map(communities, fn community ->
        url = "https://cdn.example.com/logo-#{community.id}.webp"

        community
        |> Ecto.Changeset.change(avatar_url: url, club_id: "club-#{community.id}")
        |> Repo.update!()

        id = Maps.ImageCache.key(url)

        Repo.insert!(%Maps.CachedImage{
          id: id,
          status: "saved",
          content_type: "image/webp",
          processing_version: 1,
          attempted_at: DateTime.utc_now(:second)
        })

        File.mkdir_p!(Maps.ImageCache.directory())
        path = Path.join(Maps.ImageCache.directory(), id)
        File.write!(path, "existing-logo")
        on_exit(fn -> File.rm(path) end)
        add_point(community, "no-cover-#{community.id}", ~U[2099-10-03 12:00:00Z])
        {community.map_id, "/media/meetups/#{id}?v=1"}
      end)

    original_records = Repo.aggregate(Maps.CachedImage, :count)

    {:ok, date_map} =
      MeetupMaps.create(scope, %{
        name: "Community logos",
        meetup_date: "2099-10-03",
        community_ids: Enum.map(communities, & &1.id)
      })

    data = Maps.point_data(date_map)

    for {map_id, logo} <- logos do
      point = Enum.find(date_map.points, &(&1.map_id == map_id))
      assert Enum.find(data, &(&1.id == point.id)).cover_photo_url == logo
      group = Maps.get_map(scope, map_id)
      assert hd(Maps.point_data(group)).cover_photo_url == logo
      assert Repo.get!(MapPoint, point.id).cover_photo_url == nil

      assert File.read!(Path.join(Maps.ImageCache.directory(), String.slice(logo, 15, 64))) ==
               "existing-logo"
    end

    assert Repo.aggregate(Maps.CachedImage, :count) == original_records

    [first_community | _] = communities
    pasted_map = CATools.MapsFixtures.map_fixture(scope)

    pasted_point = %{
      hd(date_map.points)
      | map_id: pasted_map.id,
        club_id: "club-#{first_community.id}"
    }

    assert hd(Maps.point_data(%{pasted_map | points: [pasted_point]})).cover_photo_url ==
             Map.new(logos)[first_community.map_id]

    other_owner = %{pasted_map | user_id: user_scope_fixture().user.id, points: [pasted_point]}
    assert hd(Maps.point_data(other_owner)).cover_photo_url == nil

    [first_point | _] = date_map.points
    first_community = Repo.get!(CATools.Communities.Community, first_community.id)
    first_community |> Ecto.Changeset.change(club_id: nil) |> Repo.update!()
    unknown = %{pasted_point | id: -1, club_id: nil}
    mixed = %{date_map | points: [first_point, unknown]}
    assert Enum.find(Maps.point_data(mixed), &(&1.id == -1)).cover_photo_url == nil

    [point | _] = date_map.points
    cover = "https://cdn.example.com/real-cover-#{nonce}.webp"
    id = Maps.ImageCache.key(cover)

    Repo.insert!(%Maps.CachedImage{
      id: id,
      status: "saved",
      content_type: "image/webp",
      processing_version: 1,
      attempted_at: DateTime.utc_now(:second)
    })

    path = Path.join(Maps.ImageCache.directory(), id)
    File.write!(path, "real-cover")
    on_exit(fn -> File.rm(path) end)
    with_cover = %{date_map | points: [%{point | cover_photo_url: cover}]}
    assert hd(Maps.point_data(with_cover)).cover_photo_url == "/media/meetups/#{id}?v=1"

    File.rm!(path)
    assert hd(Maps.point_data(with_cover)).cover_photo_url == nil
    [community | _] = communities
    community = Repo.get!(CATools.Communities.Community, community.id)
    community |> Ecto.Changeset.change(avatar_url: nil) |> Repo.update!()
    assert hd(Maps.point_data(Maps.get_map(scope, community.map_id))).cover_photo_url == nil
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
