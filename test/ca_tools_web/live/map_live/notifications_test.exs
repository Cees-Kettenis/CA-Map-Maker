defmodule CAToolsWeb.MapLive.NotificationsTest do
  use CAToolsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.{Maps, Repo}

  test "idle map pages make no repeated database requests and receive change notifications", %{
    conn: conn
  } do
    user = user_fixture()
    scope = user_scope_fixture(user)
    map = map_fixture(scope)
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    id = "idle-map-#{map.id}"

    listener = fn _, _, _, {owner, live_pid} ->
      if self() == live_pid, do: send(owner, :map_query)
    end

    :telemetry.attach(id, [:ca_tools, :repo, :query], listener, {self(), view.pid})
    on_exit(fn -> :telemetry.detach(id) end)
    refute_receive :map_query, 3_200

    Repo.insert!(%Maps.MapPoint{
      map_id: map.id,
      map_source_id: hd(map.sources).id,
      title: "New meetup",
      latitude: 3.0,
      longitude: 101.0
    })

    Maps.notify(user.id)
    assert_receive :map_query
    assert render(view) =~ "New meetup"
  end

  test "finished pins disappear at the end time without a polling loop", %{conn: conn} do
    user = user_fixture()
    map = map_fixture(user_scope_fixture(user))

    Repo.insert!(%Maps.MapPoint{
      map_id: map.id,
      map_source_id: hd(map.sources).id,
      title: "Ending soon",
      latitude: 3.0,
      longitude: 101.0,
      ends_at: DateTime.utc_now(:second) |> DateTime.add(2)
    })

    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/dashboard/maps/#{map.id}")
    assert element(view, "[data-map-points]") |> render() =~ "Ending soon"
    Process.sleep(2_100)
    refute element(view, "[data-map-points]") |> render() =~ "Ending soon"
    assert has_element?(view, "button[phx-click=toggle_past]", "Show past meetups")
  end
end
