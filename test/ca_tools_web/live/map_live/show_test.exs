defmodule CAToolsWeb.MapLive.ShowTest do
  use CAToolsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.Maps

  test "find community meetups reloads the saved local date without queueing imports", %{
    conn: conn
  } do
    user = user_fixture()
    scope = user_scope_fixture(user)

    {:ok, [one, two, three, unselected]} =
      CATools.Communities.add_links(
        scope,
        Enum.map_join(["one", "two", "three", "unselected"], "\n", fn id ->
          "https://campfire.nianticlabs.com/discover/clubs/#{id}"
        end)
      )

    add_meetup = fn community, title, starts_at ->
      url = "https://campfire.nianticlabs.com/discover/meetup/#{title}"

      source =
        CATools.Repo.insert!(%Maps.MapSource{
          map_id: community.map_id,
          original_url: url,
          status: :fetched,
          campfire_id: title
        })

      CATools.Repo.insert!(%Maps.MapPoint{
        map_id: community.map_id,
        map_source_id: source.id,
        title: title,
        campfire_id: title,
        source_url: url,
        starts_at: starts_at,
        latitude: 3.0,
        longitude: 101.0
      })
    end

    add_meetup.(one, "First meetup", ~U[2099-10-02 16:00:00Z])
    add_meetup.(two, "Second meetup", ~U[2099-10-03 12:00:00Z])

    {:ok, map} =
      CATools.MeetupMaps.create(scope, %{
        name: "Saturday communities",
        meetup_date: "2099-10-03",
        utc_offset_minutes: 480,
        community_ids: [one.id, two.id, three.id]
      })

    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    assert has_element?(view, "#find-community-meetups", "Find meetups")
    assert element(view, "[data-map-points]") |> render() =~ "First meetup"
    assert render(view) =~ "2 meetup locations"

    late = add_meetup.(three, "Late third meetup", ~U[2099-10-03 15:59:59Z])
    add_meetup.(three, "Next day meetup", ~U[2099-10-03 16:00:00Z])
    add_meetup.(three, "Previous day meetup", ~U[2099-10-02 15:59:59Z])
    add_meetup.(unselected, "Unselected meetup", ~U[2099-10-03 12:00:00Z])

    {:ok, [foreign]} =
      CATools.Communities.add_links(
        user_scope_fixture(),
        "https://campfire.nianticlabs.com/discover/clubs/foreign"
      )

    add_meetup.(foreign, "Foreign meetup", ~U[2099-10-03 12:00:00Z])
    refute render(view) =~ "Late third meetup"

    jobs = CATools.Repo.all(Oban.Job)
    sources = CATools.Repo.all(Maps.MapSource)
    points = CATools.Repo.all(Maps.MapPoint)

    view |> element("#find-community-meetups") |> render_click()
    assert has_element?(view, "#map-community-selection")
    assert has_element?(view, "#find-community-meetups[aria-expanded='true']")
    view |> element("#find-community-meetups") |> render_click()
    refute has_element?(view, "#map-community-selection")
    assert has_element?(view, "#find-community-meetups[aria-expanded='false']")
    view |> element("#find-community-meetups") |> render_click()

    for community <- [one, two, three] do
      assert has_element?(view, "#map-community-form input[value='#{community.id}'][checked]")
    end

    refute has_element?(view, "#map-community-form input[value='#{unselected.id}'][checked]")
    refute has_element?(view, "#map-community-form input[value='#{foreign.id}']")

    html =
      view
      |> form("#map-community-form", communities: %{community_ids: [one.id, two.id, three.id]})
      |> render_submit()

    assert html =~ "Found 1 new meetup from your communities."
    assert html =~ "3 meetup locations"
    assert element(view, "[data-map-points]") |> render() =~ "Late third meetup"

    for title <- ["Next day meetup", "Previous day meetup", "Unselected meetup", "Foreign meetup"] do
      refute html =~ title
    end

    assert view
           |> form("#map-community-form",
             communities: %{community_ids: [one.id, two.id, three.id]}
           )
           |> render_submit() =~
             "No new meetups found in your communities for this date."

    assert CATools.Repo.all(Oban.Job) == jobs
    assert CATools.Repo.all(Maps.MapSource) == sources
    assert CATools.Repo.all(Maps.MapPoint) == points
    assert CATools.Repo.get!(Maps.MapPoint, late.id).map_id == three.map_id
    assert Maps.get_map(scope, map.id).points_count == 3

    {:ok, public_map} = Maps.update_map(scope, map.id, %{visibility: :public})
    {:ok, public, html} = live(build_conn(), ~p"/maps/#{public_map.public_slug}")
    assert html =~ "Late third meetup"
    refute has_element?(public, "#find-community-meetups")
  end

  test "community panel includes groups added after the map and persists the selection", %{
    conn: conn
  } do
    user = user_fixture()
    scope = user_scope_fixture(user)

    {:ok, [original]} =
      CATools.Communities.add_links(
        scope,
        "https://campfire.nianticlabs.com/discover/clubs/original"
      )

    {:ok, map} =
      CATools.MeetupMaps.create(scope, %{
        name: "More communities",
        meetup_date: "2099-10-03",
        community_ids: [original.id]
      })

    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    view |> element("#find-community-meetups") |> render_click()
    view |> element("button[phx-click='close_communities']") |> render_click()
    refute has_element?(view, "#map-community-selection")

    {:ok, [added]} =
      CATools.Communities.add_links(
        scope,
        "https://campfire.nianticlabs.com/discover/clubs/added"
      )

    CATools.Repo.update!(Ecto.Changeset.change(added, club_id: "new-community-club"))

    {:ok, [cached]} =
      CATools.Communities.add_links(
        user_scope_fixture(),
        "https://campfire.nianticlabs.com/discover/clubs/added"
      )

    CATools.Repo.update!(Ecto.Changeset.change(cached, club_id: "new-community-club"))

    source =
      CATools.Repo.insert!(%Maps.MapSource{
        map_id: cached.map_id,
        original_url: "https://campfire.nianticlabs.com/discover/meetup/added-event",
        status: :fetched
      })

    CATools.Repo.insert!(%Maps.MapPoint{
      map_id: cached.map_id,
      map_source_id: source.id,
      club_id: "new-community-club",
      title: "New community meetup",
      starts_at: ~U[2099-10-03 12:00:00Z],
      latitude: 3.0,
      longitude: 101.0
    })

    jobs = CATools.Repo.all(Oban.Job)
    view |> element("#find-community-meetups") |> render_click()
    assert has_element?(view, "#map-community-form input[value='#{added.id}']")
    refute has_element?(view, "#map-community-form input[value='#{added.id}'][checked]")

    view
    |> form("#map-community-form", communities: %{community_ids: [original.id, added.id]})
    |> render_change()

    view |> element("button[phx-click='close_communities']") |> render_click()
    assert Enum.map(CATools.MeetupMaps.communities(scope, map.id), & &1.id) == [original.id]
    view |> element("#find-community-meetups") |> render_click()

    view |> element("button[phx-click='select_all_communities']") |> render_click()

    for community <- [original, added] do
      assert has_element?(view, "#map-community-form input[value='#{community.id}'][checked]")
    end

    assert view
           |> form("#map-community-form", communities: %{community_ids: [original.id, added.id]})
           |> render_submit() =~ "Found 1 new meetup"

    assert element(view, "[data-map-points]") |> render() =~ "New community meetup"

    assert Enum.map(CATools.MeetupMaps.communities(scope, map.id), & &1.id) == [
             original.id,
             added.id
           ]

    {:ok, reloaded, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    reloaded |> element("#find-community-meetups") |> render_click()
    assert has_element?(reloaded, "#map-community-form input[value='#{added.id}'][checked]")

    reloaded
    |> form("#map-community-form", communities: %{community_ids: []})
    |> render_submit()

    assert Enum.map(CATools.MeetupMaps.communities(scope, map.id), & &1.id) == [
             original.id,
             added.id
           ]

    assert has_element?(reloaded, "#map-community-selection .text-error")

    reloaded
    |> form("#map-community-form", communities: %{community_ids: [original.id]})
    |> render_submit()

    refute element(reloaded, "[data-map-points]") |> render() =~ "New community meetup"
    assert Enum.map(CATools.MeetupMaps.communities(scope, map.id), & &1.id) == [original.id]
    assert CATools.Repo.all(Oban.Job) == jobs
  end

  test "find community meetups is unavailable for pasted and community maps", %{conn: conn} do
    user = user_fixture()
    scope = user_scope_fixture(user)
    regular = map_fixture(scope)

    {:ok, [community]} =
      CATools.Communities.add_links(
        scope,
        "https://campfire.nianticlabs.com/discover/clubs/regular"
      )

    for id <- [regular.id, community.map_id] do
      {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{id}")
      refute has_element?(view, "#find-community-meetups")
      jobs = CATools.Repo.all(Oban.Job)

      assert render_click(view, "find_community_meetups") =~
               "This action is only available for date maps."

      assert CATools.Repo.all(Oban.Job) == jobs
    end
  end

  test "owners enable and revoke anonymous read-only links for regular and community maps", %{
    conn: conn
  } do
    user = user_fixture()
    scope = user_scope_fixture(user)
    regular = map_fixture(scope)

    {:ok, community} =
      CATools.Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/sharing"
      })

    source =
      CATools.Repo.insert!(%CATools.Maps.MapSource{
        map_id: community.map_id,
        original_url: "https://campfire.nianticlabs.com/discover/meetup/private-source",
        status: :fetched
      })

    CATools.Repo.insert!(%CATools.Maps.MapPoint{
      map_id: community.map_id,
      map_source_id: source.id,
      title: "Shared meetup",
      source_url: source.original_url,
      latitude: 3.139,
      longitude: 101.6869,
      starts_at: DateTime.utc_now(:second)
    })

    {:ok, date_map} =
      CATools.MeetupMaps.create(scope, %{
        name: "Shared date map",
        meetup_date: Date.utc_today(),
        community_ids: [community.id]
      })

    for id <- [regular.id, community.map_id, date_map.id] do
      {:ok, owner, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{id}")
      assert has_element?(owner, "button[phx-click='toggle_sharing']", "Make public")
      assert has_element?(owner, "#map-controls summary", "Map Controls")
      assert has_element?(owner, "#map-controls a[download] .hero-arrow-down-tray")

      assert has_element?(
               owner,
               "#map-controls .atlas-map-controls-menu > a:last-child[download]",
               "Export KML"
             )

      assert has_element?(
               owner,
               "#map-controls button[phx-click='toggle_sharing'] .hero-globe-alt"
             )

      refute has_element?(owner, "#share_url")
      refute has_element?(owner, "#map-sharing")
      refute has_element?(owner, "a", "Open public map")

      owner |> element("button[phx-click='toggle_sharing']") |> render_click()
      map = Maps.get_map(scope, id)
      assert map.visibility == :public
      assert has_element?(owner, "#copy-share[data-url$='/maps/#{map.public_slug}']")
      assert has_element?(owner, "#copy-share", "Copy public link")
      assert has_element?(owner, "#map-controls #copy-share .hero-clipboard-document")
      assert has_element?(owner, "#copy-share [data-copy-label]", "Copy public link")

      assert has_element?(
               owner,
               "#map-controls button[phx-click='toggle_sharing'] .hero-lock-closed"
             )

      assert has_element?(owner, "button[phx-click='toggle_sharing']", "Make private")
      refute has_element?(owner, "button[phx-click='toggle_sharing']", "Make public")

      {:ok, public, html} = live(build_conn(), ~p"/maps/#{map.public_slug}")
      refute html =~ user.email

      if id != regular.id do
        assert html =~ "Shared meetup"

        assert has_element?(
                 public,
                 "a[href='#{source.original_url}'][target='_blank'][rel='noopener noreferrer']",
                 "View on Campfire"
               )
      end

      assert has_element?(public, "#public-map")
      refute has_element?(public, "button[phx-click='edit']")
      refute has_element?(public, "button[phx-click='delete']")
      refute has_element?(public, "button[phx-click='update_now']")
      refute has_element?(public, "button[phx-click='toggle_sharing']")
      assert {:error, :not_found} = Maps.update_map(user_scope_fixture(), id, %{name: "Changed"})

      export = response(get(build_conn(), ~p"/maps/#{map.public_slug}/export.kml"), 200)
      refute export =~ source.original_url

      owner |> element("button[phx-click='toggle_sharing']") |> render_click()
      assert has_element?(owner, "button[phx-click='toggle_sharing']", "Make public")
      refute has_element?(owner, "#copy-share")
      assert Maps.get_public_map(map.public_slug) == nil
      send(public.pid, :refresh)
      assert_redirect(public, ~p"/")
      assert response(get(build_conn(), ~p"/maps/#{map.public_slug}/points"), 404)
      assert response(get(build_conn(), ~p"/maps/#{map.public_slug}/export.kml"), 404)
    end
  end

  test "update now starts pending links without displaying batches", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    refute has_element?(view, "#map-import-progress")
    view |> element("button[phx-click='toggle_progress']") |> render_click()
    assert has_element?(view, "button[phx-click='update_now']", "Update now")
    refute render(view) =~ "Batch #"
    assert render(view) =~ "Last updated"
    assert render(view) =~ "Scheduled update"

    assert view |> element("button[phx-click='update_now']") |> render_click() =~
             "Update started."

    for source <- map.sources do
      assert CATools.Repo.get!(CATools.Maps.MapSource, source.id).next_fetch_at
    end
  end

  test "meetup cards display cover photos and export links are marked as downloads", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))

    CATools.Repo.insert!(
      Ecto.Changeset.change(%CATools.Maps.MapPoint{},
        map_id: map.id,
        map_source_id: hd(map.sources).id,
        title: "Cover meetup",
        starts_at: ~U[2026-10-03 06:00:00Z],
        ends_at: ~U[2099-10-03 10:00:00Z],
        latitude: 3.139,
        longitude: 101.68,
        cover_photo_url: "https://cdn.example.com/cover.jpg",
        host_name: "Trainer Host",
        host_avatar_url: "https://cdn.example.com/avatar.jpg"
      )
    )

    for url <- ["https://cdn.example.com/cover.jpg", "https://cdn.example.com/avatar.jpg"] do
      CATools.Repo.insert!(%CATools.Maps.CachedImage{
        id: CATools.Maps.ImageCache.key(url),
        content_type: "image/jpeg",
        attempted_at: DateTime.utc_now(:second)
      })

      File.mkdir_p!(CATools.Maps.ImageCache.directory())

      File.write!(
        Path.join(CATools.Maps.ImageCache.directory(), CATools.Maps.ImageCache.key(url)),
        <<255, 216, 255>>
      )
    end

    cover = "/media/meetups/" <> CATools.Maps.ImageCache.key("https://cdn.example.com/cover.jpg")

    avatar =
      "/media/meetups/" <> CATools.Maps.ImageCache.key("https://cdn.example.com/avatar.jpg")

    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    assert has_element?(view, "img[src='#{cover}'][alt='Cover meetup']")

    assert has_element?(
             view,
             "time[datetime='2026-10-03T06:00:00Z'][data-ends-at='2099-10-03T10:00:00Z'][phx-hook='LocalTime']"
           )

    assert has_element?(view, ".atlas-meetup-host", "Trainer Host")
    assert has_element?(view, ".atlas-meetup-host img[src='#{avatar}']")
    assert has_element?(view, "a[href='/dashboard/maps/#{map.id}/export.kml'][download]")
    {:ok, map} = Maps.update_map(user_scope_fixture(user), map.id, %{visibility: "public"})
    {:ok, public, _} = live(conn, ~p"/maps/#{map.public_slug}")
    assert has_element?(public, "img[src='#{cover}']")

    assert has_element?(
             public,
             "time[datetime='2026-10-03T06:00:00Z'][data-ends-at='2099-10-03T10:00:00Z'][phx-hook='LocalTime']"
           )

    assert has_element?(public, ".atlas-meetup-host", "Trainer Host")
    assert has_element?(public, "a[download]")
  end

  test "owner edits metadata and visibility, then deletes their map", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))
    {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    assert html =~ "Updates"
    view |> element("button", "Edit map") |> render_click()

    assert view
           |> form("#edit_map_form", map: %{name: "My new name", visibility: "public"})
           |> render_submit() =~ "My new name"

    assert has_element?(view, "#copy-share")
    assert Maps.get_map(user_scope_fixture(user), map.id).visibility == :public
    view |> element("#delete-map-dialog button[phx-click='delete']") |> render_click()
    assert_redirect(view, ~p"/dashboard/maps")
    assert Maps.get_map(user_scope_fixture(user), map.id) == nil
  end

  test "other owners cannot open a private map", %{conn: conn} do
    map = map_fixture(user_scope_fixture())

    assert_raise CAToolsWeb.NotFoundError, fn ->
      conn |> log_in_user(user_fixture()) |> live(~p"/dashboard/maps/#{map.id}")
    end
  end

  test "public maps render without login and private maps return 404", %{conn: conn} do
    scope = user_scope_fixture()
    map = map_fixture(scope, %{"visibility" => "public"})
    {:ok, _view, html} = live(conn, ~p"/maps/#{map.public_slug}")
    assert html =~ map.name
    refute html =~ scope.user.email
    refute html =~ "encrypted_credentials"
    refute html =~ "https://cmpf.re"
    {:ok, _} = Maps.update_map(scope, map.id, %{"visibility" => "private"})
    assert_raise CAToolsWeb.NotFoundError, fn -> live(conn, ~p"/maps/#{map.public_slug}") end
  end

  test "open public maps receive imported points and close when made private", %{conn: conn} do
    scope = user_scope_fixture()
    map = map_fixture(scope, %{"visibility" => "public"})
    {:ok, view, _html} = live(conn, ~p"/maps/#{map.public_slug}")

    CATools.Repo.insert!(
      Ecto.Changeset.change(%CATools.Maps.MapPoint{},
        map_id: map.id,
        map_source_id: hd(map.sources).id,
        title: "Newly imported park",
        latitude: 3.139,
        longitude: 101.6869
      )
    )

    send(view.pid, :refresh)
    assert render(view) =~ "Newly imported park"
    assert render(view) =~ "1 meetup locations"
    {:ok, _} = Maps.update_map(scope, map.id, %{"visibility" => "private"})
    send(view.pid, :refresh)
    assert_redirect(view, ~p"/")
  end
end
