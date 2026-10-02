defmodule CAToolsWeb.CommunityLive.MultipleGroupsTest do
  use CAToolsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  alias CATools.{Communities, Maps}

  test "paste groups, select one, then create a linked date map", %{conn: conn} do
    user = user_fixture()
    scope = user_scope_fixture(user)
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, ~p"/dashboard/community")

    view
    |> form("#community-links-form",
      groups: %{
        links:
          "https://campfire.nianticlabs.com/discover/clubs/one\nhttps://campfire.nianticlabs.com/discover/clubs/two"
      }
    )
    |> render_submit()

    [one, two] = Communities.list(scope)

    assert has_element?(
             view,
             "nav[aria-label='Tracked communities'] button",
             "/discover/clubs/two"
           )

    view |> element("button[phx-click='select'][phx-value-id='#{two.id}']") |> render_click()

    view
    |> form("#community-form", community: %{enabled: false, source_url: two.source_url})
    |> render_submit()

    assert Communities.get(scope, one.id).enabled
    refute Communities.get(scope, two.id).enabled

    {:ok, maps_view, _} = live(conn, ~p"/dashboard/maps")
    assert has_element?(maps_view, "#meetup-map-form")

    maps_view
    |> form("#meetup-map-form",
      meetup: %{
        name: "Our Saturday",
        meetup_date: "2026-10-03",
        community_ids: ["#{one.id}", "#{two.id}"]
      }
    )
    |> render_submit()

    map = Enum.find(Maps.list_maps(scope), &(&1.name == "Our Saturday"))
    assert_redirect(maps_view, ~p"/dashboard/maps/#{map.id}")
    assert map.meetup_date == ~D[2026-10-03]
    {:ok, map_view, html} = live(conn, ~p"/dashboard/maps/#{map.id}")
    refute html =~ "Linked communities"
    map_view |> element("button[phx-click='toggle_progress']") |> render_click()
    assert render(map_view) =~ "Scheduled update"
    assert has_element?(map_view, "button", "Update now")
    refute has_element?(map_view, "button", "Refresh all links")
  end
end
