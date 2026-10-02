defmodule CAToolsWeb.MapLive.ImageUploadTest do
  use CAToolsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.Maps

  test "uploaded map images persist on cards and owner and public titles", %{conn: conn} do
    user = user_fixture()
    scope = user_scope_fixture(user)
    map = map_fixture(scope, %{"visibility" => "public"})
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    view |> element("button[phx-click='edit']") |> render_click()

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII="
      )

    upload =
      file_input(view, "#edit_map_form", :map_image, [
        %{name: "map.png", content: png, type: "image/png"}
      ])

    assert render_upload(upload, "map.png") =~ "Remove selection"

    view
    |> form("#edit_map_form", map: %{name: map.name, visibility: "public"})
    |> render_submit()

    saved = Maps.get_map(scope, map.id)
    assert saved.image_id
    url = Maps.image_url(saved)
    assert {:ok, _, "image/png"} = Maps.ImageCache.file(saved.image_id)
    assert has_element?(view, "img[src='#{url}']")
    {:ok, cards, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps")
    assert has_element?(cards, ".atlas-map-card img[src='#{url}']")
    refute has_element?(cards, ".atlas-map-card progress")
    {:ok, shared, _} = live(conn, ~p"/maps/#{map.public_slug}")
    assert has_element?(shared, "img[src='#{url}']")
    assert get(conn, url) |> response(200) == png
  end

  test "image uploads reject disguised HTML without saving it", %{conn: conn} do
    user = user_fixture()
    scope = user_scope_fixture(user)
    map = map_fixture(scope)
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    view |> element("button[phx-click='edit']") |> render_click()

    upload =
      file_input(view, "#edit_map_form", :map_image, [
        %{name: "fake.png", content: "<script>alert(1)</script>", type: "image/png"}
      ])

    render_upload(upload, "fake.png")

    html =
      view
      |> form("#edit_map_form", map: %{name: map.name, visibility: "private"})
      |> render_submit()

    assert html =~ "Could not save the image"
    assert Maps.get_map(scope, map.id).image_id == nil
  end
end
