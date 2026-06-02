defmodule CATools.MapsTest do
  use CATools.DataCase, async: true

  alias CATools.Maps

  import CATools.AccountsFixtures
  import CATools.MapsFixtures

  describe "normalize_source_urls/1" do
    test "normalizes supported Campfire URLs, strips fragments, and removes duplicates" do
      input = """
      https://CMPF.RE/abc123#section
      https://campfire.nianticlabs.com/discover/meetups/xyz987
      https://cmpf.re/abc123
      """

      assert {:ok,
              [
                "https://cmpf.re/abc123",
                "https://campfire.nianticlabs.com/discover/meetups/xyz987"
              ]} = Maps.normalize_source_urls(input)
    end

    test "rejects unsupported domains" do
      assert {:error, [message]} =
               Maps.normalize_source_urls("https://example.com/campfire-link")

      assert message =~ "unsupported host example.com"
    end

    test "rejects custom ports and embedded credentials" do
      assert {:error, [message]} =
               Maps.normalize_source_urls("https://user:pass@cmpf.re:444/abc123")

      assert message =~ "must not include embedded credentials"
    end
  end

  describe "maps" do
    setup do
      user = user_fixture()
      other_user = user_fixture()

      %{
        scope: user_scope_fixture(user),
        other_scope: user_scope_fixture(other_user)
      }
    end

    test "create_map/2 creates the map and source records", %{scope: scope} do
      assert {:ok, map} =
               Maps.create_map(scope, %{
                 "description" => "Pokemon GO meetup links",
                 "name" => "West Coast Raids",
                 "source_urls_input" =>
                   "https://cmpf.re/abc123\nhttps://campfire.nianticlabs.com/discover/meetups/xyz987",
                 "visibility" => "public"
               })

      assert map.name == "West Coast Raids"
      assert map.visibility == :public
      assert is_binary(map.public_slug)
      assert map.sources_count == 2

      assert Enum.sort(Enum.map(map.sources, & &1.original_url)) == [
               "https://campfire.nianticlabs.com/discover/meetups/xyz987",
               "https://cmpf.re/abc123"
             ]
    end

    test "change_map/2 returns validation errors for unsupported links", %{scope: scope} do
      changeset =
        Maps.change_map(scope, %{
          "name" => "Invalid Map",
          "source_urls_input" => "https://example.com/nope",
          "visibility" => "private"
        })

      assert "Line 1: unsupported host example.com. Only cmpf.re and campfire.nianticlabs.com are allowed." in errors_on(
               changeset
             ).source_urls_input
    end

    test "list_maps/1 returns only maps owned by the current user", %{
      scope: scope,
      other_scope: other_scope
    } do
      owned_map = map_fixture(scope, %{"name" => "Owned Map"})
      _other_map = map_fixture(other_scope, %{"name" => "Other Map"})

      assert [listed_map] = Maps.list_maps(scope)
      assert listed_map.id == owned_map.id
    end

    test "get_map/2 does not expose another user's map", %{scope: scope, other_scope: other_scope} do
      map = map_fixture(other_scope)

      assert Maps.get_map(scope, map.id) == nil
    end

    test "create_map/2 requires an authenticated scope" do
      assert {:error, :unauthorized} = Maps.create_map(nil, valid_map_attributes())
    end
  end
end
