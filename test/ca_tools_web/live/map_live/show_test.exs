defmodule CAToolsWeb.MapLive.ShowTest do
  use CAToolsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.Maps

  test "temporary force-fetch button starts its selected batch", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    assert has_element?(view, "button[phx-click='force_fetch_batch']", "Force fetch now")

    assert view |> element("button[phx-click='force_fetch_batch']") |> render_click() =~
             "2 imports started immediately."

    assert CATools.Repo.get!(CATools.Maps.ImportBatch, hd(map.batches).id).status == :processing
  end

  test "meetup cards display cover photos and export links are marked as downloads", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))

    CATools.Repo.insert!(
      Ecto.Changeset.change(%CATools.Maps.MapPoint{},
        map_id: map.id,
        map_source_id: hd(map.sources).id,
        title: "Cover meetup",
        latitude: 3.139,
        longitude: 101.68,
        cover_photo_url: "https://cdn.example.com/cover.jpg",
        host_name: "Trainer Host",
        host_avatar_url: "https://cdn.example.com/avatar.jpg"
      )
    )

    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    assert has_element?(view, "img[src='https://cdn.example.com/cover.jpg'][alt='Cover meetup']")
    assert has_element?(view, ".atlas-meetup-host", "Trainer Host")
    assert has_element?(view, ".atlas-meetup-host img[src='https://cdn.example.com/avatar.jpg']")
    assert has_element?(view, "a[href='/dashboard/maps/#{map.id}/export.kml'][download]")
    {:ok, map} = Maps.update_map(user_scope_fixture(user), map.id, %{visibility: "public"})
    {:ok, public, _} = live(conn, ~p"/maps/#{map.public_slug}")
    assert has_element?(public, "img[src='https://cdn.example.com/cover.jpg']")
    assert has_element?(public, ".atlas-meetup-host", "Trainer Host")
    assert has_element?(public, "a[download]")
  end

  test "owner edits metadata and visibility, then deletes their map", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))
    {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    assert html =~ "Import progress"
    view |> element("button", "Edit map") |> render_click()

    assert view
           |> form("#edit_map_form", map: %{name: "My new name", visibility: "public"})
           |> render_submit() =~ "My new name"

    assert has_element?(view, "#share_url")
    assert Maps.get_map(user_scope_fixture(user), map.id).visibility == :public
    view |> element("button", "Delete map") |> render_click()
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
