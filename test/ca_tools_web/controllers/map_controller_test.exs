defmodule CAToolsWeb.MapControllerTest do
  use CAToolsWeb.ConnCase, async: true
  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  alias CATools.Maps
  alias CATools.Maps.{MapPoint, UserMap}
  alias CATools.Repo

  setup do
    user = user_fixture()

    map =
      map_fixture(user_scope_fixture(user), %{
        "visibility" => "public",
        "name" => "Meetups & friends"
      })

    point =
      Repo.insert!(
        Ecto.Changeset.change(%MapPoint{},
          map_id: map.id,
          map_source_id: hd(map.sources).id,
          title: "Park <meetup> & friends",
          description: "<script>alert('x')</script>",
          group_name: "Trainers",
          latitude: 3.139,
          longitude: 101.6869,
          source_url: "https://cmpf.re/private-source",
          campfire_id: "private-event-id"
        )
      )

    %{user: user, map: map, point: point}
  end

  test "public JSON includes only safe metadata", %{conn: conn, map: map, user: user} do
    data = conn |> get(~p"/maps/#{map.public_slug}/points") |> json_response(200)
    assert data["name"] == map.name
    assert [point] = data["points"]
    assert point["latitude"] == 3.139

    for key <- ["source_url", "campfire_id", "payload_hash", "map_id", "map_source_id"] do
      refute Map.has_key?(point, key)
    end

    refute Jason.encode!(data) =~ user.email
    refute Jason.encode!(data) =~ "encrypted_credentials"
  end

  test "public JSON supplies resolved Campfire links for map popups", %{
    conn: conn,
    map: map,
    point: point
  } do
    url = "https://campfire.nianticlabs.com/discover/meetup/event-id"
    Repo.update!(Ecto.Changeset.change(point, source_url: url <> "?token=secret"))
    data = conn |> get(~p"/maps/#{map.public_slug}/points") |> json_response(200)
    assert [point] = data["points"]
    assert point["campfire_url"] == url
    refute Map.has_key?(point, "source_url")
    refute Jason.encode!(data) =~ "secret"
  end

  test "public KML escapes XML and omits source links", %{conn: conn, map: map} do
    conn = get(conn, ~p"/maps/#{map.public_slug}/export.kml")
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/vnd.google-earth.kml+xml"
    body = response(conn, 200)
    assert body =~ "101.6869,3.139,0"
    assert body =~ "&lt;meetup&gt; &amp; friends"
    refute body =~ "private-source"
    assert {_doc, []} = :xmerl_scan.string(String.to_charlist(body))
  end

  test "private and invalid public slugs return 404", %{conn: conn, map: map} do
    Repo.update!(Ecto.Changeset.change(map, visibility: :private))
    assert conn |> get(~p"/maps/#{map.public_slug}/points") |> json_response(404)
    assert conn |> get(~p"/maps/#{map.public_slug}/export.kml") |> response(404)
    assert conn |> get(~p"/maps/missing/points") |> json_response(404)
  end

  test "owner export includes sources and denies other owners", %{
    conn: conn,
    map: map,
    user: user
  } do
    assert conn
           |> log_in_user(user)
           |> get(~p"/dashboard/maps/#{map.id}/export.kml")
           |> response(200) =~ "private-source"

    assert conn
           |> log_in_user(user_fixture())
           |> get(~p"/dashboard/maps/#{map.id}/export.kml")
           |> response(404)
  end

  test "empty and large KML maps are valid XML", %{map: map, point: point} do
    empty = CATools.Maps.KML.generate(%UserMap{name: "Empty", points: []})
    assert {_doc, []} = :xmerl_scan.string(String.to_charlist(empty))

    large =
      CATools.Maps.KML.generate(%{
        Maps.get_public_map(map.public_slug)
        | points: List.duplicate(point, 1_000)
      })

    assert length(Regex.scan(~r/<Placemark>/, large)) == 1_000
    assert {_doc, []} = :xmerl_scan.string(String.to_charlist(large))
  end

  test "KML removes invalid XML controls while preserving Unicode", %{map: map, point: point} do
    kml =
      CATools.Maps.KML.generate(%{
        Maps.get_public_map(map.public_slug)
        | name: "Map\x00 & friends",
          points: [%{point | title: "Café\x01 東京", description: "A\x0B park\n🌳"}]
      })

    assert kml =~ "Café 東京"
    assert kml =~ "A park\n🌳"
    assert {_doc, []} = :xmerl_scan.string(:binary.bin_to_list(kml))
  end
end
