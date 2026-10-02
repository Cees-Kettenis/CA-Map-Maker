defmodule CAToolsWeb.MapLive.LifecycleTest do
  use CAToolsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.{Communities, Maps, Repo}

  test "progress is opt-in, source list is removed, and delete uses a dialog", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    refute has_element?(view, "#map-import-progress")
    refute has_element?(view, "h2", "Source links")
    assert has_element?(view, "dialog#delete-map-dialog[phx-hook='ConfirmDialog']")
    view |> element("button[phx-click='toggle_progress']") |> render_click()
    assert has_element?(view, "#map-import-progress")
    view |> element("button[phx-click='toggle_progress']") |> render_click()
    refute has_element?(view, "#map-import-progress")
    assert Maps.get_map(user_scope_fixture(user), map.id)
  end

  test "finished events can be shown in cards but never in map pins or public point data", %{
    conn: conn
  } do
    user = user_fixture()
    scope = user_scope_fixture(user)
    map = map_fixture(scope, %{"visibility" => "public"})
    now = DateTime.utc_now(:second)

    for {source, title, end_offset} <-
          Enum.zip([map.sources, ["Finished meetup", "Still happening"], [-1, 3600]]) do
      Repo.insert!(%Maps.MapPoint{
        map_id: map.id,
        map_source_id: source.id,
        title: title,
        latitude: 3.0,
        longitude: 101.0,
        starts_at: DateTime.add(now, -3600),
        ends_at: DateTime.add(now, end_offset)
      })
    end

    for {viewer, path} <- [
          {log_in_user(conn, user), ~p"/dashboard/maps/#{map.id}"},
          {conn, ~p"/maps/#{map.public_slug}"}
        ] do
      {:ok, view, _} = live(viewer, path)
      refute has_element?(view, "article h3", "Finished meetup")
      assert has_element?(view, "article h3", "Still happening")
      view |> element("button[phx-click='toggle_past']") |> render_click()
      assert has_element?(view, "article h3", "Finished meetup")
      refute element(view, "[data-map-points]") |> render() =~ "Finished meetup"
      assert element(view, "[data-map-points]") |> render() =~ "Still happening"
    end

    response = get(conn, ~p"/maps/#{map.public_slug}/points") |> json_response(200)
    assert Enum.map(response["points"], & &1["title"]) == ["Still happening"]
    refute Maps.KML.generate(Maps.get_map(scope, map.id)) =~ "Finished meetup"
  end

  test "deleted community maps disappear from open tabs and stale clicks are harmless", %{
    conn: conn
  } do
    user = user_fixture()
    scope = user_scope_fixture(user)

    {:ok, [one, two]} =
      Communities.add_links(
        scope,
        "https://campfire.nianticlabs.com/discover/clubs/one\nhttps://campfire.nianticlabs.com/discover/clubs/two"
      )

    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/community")
    assert {:ok, _} = Maps.delete_map(scope, one.map_id)
    send(view.pid, :refresh)
    refute has_element?(view, "nav button[phx-value-id='#{one.id}']")
    assert has_element?(view, "nav button[phx-value-id='#{two.id}'][aria-pressed='true']")
    render_click(view, "select", %{"id" => "#{one.id}"})
    assert Process.alive?(view.pid)

    view
    |> element("#delete-community-dialog button[phx-click='delete_community']")
    |> render_click()

    refute has_element?(view, "#community-map")
    assert Communities.list(scope) == []
    render_click(view, "retry_images", %{})
    assert Process.alive?(view.pid)
  end

  test "community map cards use a locally cached group icon", %{conn: conn} do
    user = user_fixture()
    scope = user_scope_fixture(user)

    {:ok, [community]} =
      Communities.add_links(scope, "https://campfire.nianticlabs.com/discover/clubs/icon-group")

    url = "https://cdn.example.com/#{System.unique_integer([:positive])}-group.png"
    Repo.update!(Ecto.Changeset.change(community, avatar_url: url))
    id = Maps.ImageCache.key(url)

    Repo.insert!(%Maps.CachedImage{
      id: id,
      content_type: "image/png",
      status: "saved",
      attempted_at: DateTime.utc_now(:second)
    })

    File.mkdir_p!(Maps.ImageCache.directory())
    File.write!(Path.join(Maps.ImageCache.directory(), id), <<137, 80, 78, 71>>)
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps")
    assert has_element?(view, ".atlas-community-cover img[src='/media/meetups/#{id}']")
    {:ok, owner, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{community.map_id}")
    assert has_element?(owner, "main img[src='/media/meetups/#{id}']")
    owner |> element("button[phx-click='edit']") |> render_click()
    refute has_element?(owner, "input[type=file]")
    assert Communities.delete(scope, nil) == {:error, :not_found}
    assert Communities.get(scope, community.id)
  end
end
