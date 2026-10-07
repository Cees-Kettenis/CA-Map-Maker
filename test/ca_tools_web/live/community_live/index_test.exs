defmodule CAToolsWeb.CommunityLive.IndexTest do
  use CAToolsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  alias CATools.{Communities, Maps}

  test "copy public link enables public sharing without navigating or changing invitations", %{
    conn: conn
  } do
    user = user_fixture()
    scope = user_scope_fixture(user)

    {:ok, community} =
      Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/shared"
      })

    {:ok, _} = Communities.invite(scope, %{email: "friend@example.com"}, community.id)
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/community")
    assert Maps.get_map(scope, community.map_id).visibility == :private
    refute has_element?(view, "#community-sharing a", "Manage public link")

    render_hook(view, "copy_public_link", %{})
    map = Maps.get_map(scope, community.map_id)
    assert map.visibility == :public
    assert Maps.get_public_map(map.public_slug).id == map.id
    assert [%{email: "friend@example.com"}] = Communities.get(scope, community.id).invitations

    assert has_element?(
             view,
             "#copy-community-public-link[data-prepare-event='copy_public_link']"
           )

    render_hook(view, "copy_public_link", %{})
    assert Maps.get_map(scope, community.map_id).public_slug == map.public_slug
  end

  test "owner connects a group, invites an email, and revokes access", %{conn: conn} do
    user = user_fixture()
    {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/dashboard/community")
    assert html =~ "My Communities"
    assert has_element?(view, "#community-form")

    view
    |> form("#community-form",
      community: %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/group-one",
        enabled: true
      }
    )
    |> render_submit()

    assert has_element?(view, "#community-map")
    refute has_element?(view, "#campfire-group-settings h2", "Updates")
    assert has_element?(view, "#campfire-group-settings h2", "Group Settings")
    refute has_element?(view, "#community-updates")

    assert has_element?(
             view,
             "#group-link-warning",
             "Changing the group link replaces the map and its meetups"
           )

    assert has_element?(
             view,
             "#campfire-group-settings button[phx-click='check'] .hero-arrow-path"
           )

    assert has_element?(view, "a[download]")
    community = Communities.get(user_scope_fixture(user))

    assert has_element?(
             view,
             "#copy-community-link[data-url$='/community/maps/#{community.map_id}']"
           )

    assert has_element?(
             view,
             "#campfire-group-settings button.atlas-button-danger",
             "Delete"
           )

    view
    |> form("#community-invite-form", invitation: %{email: "friend@example.com"})
    |> render_submit()

    assert render(view) =~ "friend@example.com"
    view |> element("button", "Revoke") |> render_click()
    refute render(view) =~ "friend@example.com"
  end

  test "invited accounts view and export while anonymous and uninvited accounts cannot", %{
    conn: conn
  } do
    owner = user_scope_fixture()
    invited = user_fixture()

    {:ok, community} =
      Communities.save(owner, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/group-one"
      })

    {:ok, _} = Communities.invite(owner, %{email: invited.email})
    invited_conn = log_in_user(conn, invited)
    {:ok, view, html} = live(invited_conn, ~p"/community/maps/#{community.map_id}")
    assert html =~ "My Community"
    refute html =~ owner.user.email
    refute html =~ "group-one"
    refute has_element?(view, "button", "Edit map")

    assert response(get(invited_conn, ~p"/community/maps/#{community.map_id}/export.kml"), 200) =~
             "<kml"

    assert redirected_to(get(conn, ~p"/community/maps/#{community.map_id}/export.kml")) ==
             ~p"/auth/users/log-in"

    other_conn = log_in_user(conn, user_fixture())

    assert response(get(other_conn, ~p"/community/maps/#{community.map_id}/export.kml"), 404) ==
             "Map not found"

    assert_raise CAToolsWeb.NotFoundError, fn ->
      live(other_conn, ~p"/community/maps/#{community.map_id}")
    end

    [invitation] = Communities.get(owner).invitations
    Communities.revoke(owner, invitation.id)
    send(view.pid, :refresh)
    assert_redirect(view, ~p"/")

    assert response(get(invited_conn, ~p"/community/maps/#{community.map_id}/export.kml"), 404) ==
             "Map not found"
  end

  test "community settings require authentication and reject invalid links", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/users/log-in"}}} =
             live(conn, ~p"/dashboard/community")

    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/dashboard/community")

    assert view
           |> form("#community-form", community: %{source_url: "https://example.com/group"})
           |> render_submit() =~ "unsupported host"
  end
end
