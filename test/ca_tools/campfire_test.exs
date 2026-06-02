defmodule CATools.CampfireTest do
  use CATools.DataCase, async: true

  alias CATools.Accounts
  alias CATools.Campfire.{DataNormalizer, GraphQLClient, Importer, LinkResolver}
  alias CATools.Maps.MapPoint
  alias CATools.Repo

  import CATools.AccountsFixtures
  import CATools.MapsFixtures

  describe "LinkResolver.resolve_source_url/2" do
    test "resolves a short link and extracts a meetup id" do
      Req.Test.stub(__MODULE__.ResolverStub, fn conn ->
        case {conn.host, conn.request_path} do
          {"cmpf.re", "/abc123"} ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "https://campfire.nianticlabs.com/discover/meetups/meetup-123"
            )
            |> Plug.Conn.resp(302, "")

          {"campfire.nianticlabs.com", "/discover/meetups/meetup-123"} ->
            Plug.Conn.resp(conn, 200, "")
        end
      end)

      assert {:ok, resolved_source} =
               LinkResolver.resolve_source_url(
                 "https://cmpf.re/abc123",
                 request_options: [plug: {Req.Test, __MODULE__.ResolverStub}]
               )

      assert resolved_source == %{
               resolved_url: "https://campfire.nianticlabs.com/discover/meetups/meetup-123",
               campfire_id: "meetup-123",
               resource_type: :meetup
             }
    end

    test "rejects redirects to unsupported hosts" do
      Req.Test.stub(__MODULE__.ResolverBlockedStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "https://example.com/discover/meetups/meetup-123"
        )
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, error_details} =
               LinkResolver.resolve_source_url(
                 "https://cmpf.re/abc123",
                 request_options: [plug: {Req.Test, __MODULE__.ResolverBlockedStub}]
               )

      assert error_details.code == "invalid_redirect"
    end
  end

  describe "GraphQLClient.fetch_resource/3" do
    test "uses the saved Campfire token and returns the extracted resource" do
      user =
        user_fixture()
        |> then(fn user ->
          {:ok, updated_user} =
            Accounts.update_user_campfire_token(user, %{
              "campfire_token_input" => "campfire-token"
            })

          updated_user
        end)

      Req.Test.stub(__MODULE__.GraphQLStub, fn conn ->
        assert ["Bearer campfire-token"] == Plug.Conn.get_req_header(conn, "authorization")
        assert conn.request_path == "/api/graphql"

        Req.Test.json(conn, %{
          "data" => %{
            "node" => %{
              "id" => "meetup-123",
              "title" => "Community Raid Hour",
              "description" => "Local meetup",
              "startTime" => "2026-06-02T10:00:00Z",
              "endTime" => "2026-06-02T11:00:00Z",
              "location" => %{
                "latitude" => 3.139,
                "longitude" => 101.6869,
                "address" => "Kuala Lumpur"
              },
              "group" => %{"name" => "Downtown Raiders"}
            }
          }
        })
      end)

      assert {:ok, resource} =
               GraphQLClient.fetch_resource(
                 user,
                 %{
                   resolved_url: "https://campfire.nianticlabs.com/discover/meetups/meetup-123",
                   campfire_id: "meetup-123",
                   resource_type: :meetup
                 },
                 request_options: [plug: {Req.Test, __MODULE__.GraphQLStub}]
               )

      assert resource.campfire_id == "meetup-123"
      assert resource.resource_type == :meetup
      assert resource.resource["title"] == "Community Raid Hour"
    end

    test "returns graphql errors from the response body" do
      user =
        user_fixture()
        |> then(fn user ->
          {:ok, updated_user} =
            Accounts.update_user_campfire_token(user, %{
              "campfire_token_input" => "campfire-token"
            })

          updated_user
        end)

      Req.Test.stub(__MODULE__.GraphQLErrorStub, fn conn ->
        Req.Test.json(conn, %{
          "errors" => [%{"message" => "Unauthorized"}]
        })
      end)

      assert {:error, error_details} =
               GraphQLClient.fetch_resource(
                 user,
                 %{
                   resolved_url: "https://campfire.nianticlabs.com/discover/meetups/meetup-123",
                   campfire_id: "meetup-123",
                   resource_type: :meetup
                 },
                 request_options: [plug: {Req.Test, __MODULE__.GraphQLErrorStub}]
               )

      assert error_details.code == "graphql_error"
      assert error_details.message =~ "Unauthorized"
    end
  end

  describe "DataNormalizer.normalize_map_point/2" do
    test "normalizes a resource payload into map point attributes" do
      assert {:ok, attrs} =
               DataNormalizer.normalize_map_point(
                 %{
                   campfire_id: "meetup-123",
                   resource_type: :meetup,
                   resource: %{
                     "title" => "  Community Day  ",
                     "description" => "Meet at the park",
                     "startTime" => "2026-06-02T10:00:00Z",
                     "endTime" => "2026-06-02T11:00:00Z",
                     "location" => %{
                       "latitude" => "3.139",
                       "longitude" => "101.6869",
                       "address" => "Kuala Lumpur"
                     },
                     "group" => %{"name" => "Trainers"}
                   }
                 },
                 %{
                   resolved_url: "https://campfire.nianticlabs.com/discover/meetups/meetup-123",
                   campfire_id: "meetup-123",
                   resource_type: :meetup
                 }
               )

      assert attrs.title == "Community Day"
      assert attrs.group_name == "Trainers"
      assert attrs.latitude == 3.139
      assert attrs.longitude == 101.6869
      assert attrs.address == "Kuala Lumpur"
      assert %DateTime{} = attrs.starts_at
      assert %DateTime{} = attrs.ends_at
      assert is_binary(attrs.payload_hash)
    end
  end

  describe "Importer.import_source/2" do
    test "imports a source, stores a map point, and updates source status" do
      user =
        user_fixture()
        |> then(fn user ->
          {:ok, updated_user} =
            Accounts.update_user_campfire_token(user, %{
              "campfire_token_input" => "campfire-token"
            })

          updated_user
        end)

      map =
        map_fixture(user_scope_fixture(user), %{
          "source_urls_input" => "https://cmpf.re/import123"
        })

      source = List.first(map.sources)

      Req.Test.stub(__MODULE__.ImporterStub, fn conn ->
        case {conn.host, conn.request_path} do
          {"cmpf.re", "/import123"} ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "https://campfire.nianticlabs.com/discover/meetups/meetup-789"
            )
            |> Plug.Conn.resp(302, "")

          {"campfire.nianticlabs.com", "/discover/meetups/meetup-789"} ->
            Plug.Conn.resp(conn, 200, "")

          {"campfire.nianticlabs.com", "/api/graphql"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "node" => %{
                  "id" => "meetup-789",
                  "title" => "Evening Meetup",
                  "description" => "Bring lures",
                  "startTime" => "2026-06-02T10:00:00Z",
                  "endTime" => "2026-06-02T11:30:00Z",
                  "location" => %{
                    "latitude" => 3.139,
                    "longitude" => 101.6869,
                    "address" => "Central Park"
                  },
                  "group" => %{"name" => "City Raiders"}
                }
              }
            })
        end
      end)

      assert {:ok, imported_source} =
               Importer.import_source(
                 source.id,
                 request_options: [plug: {Req.Test, __MODULE__.ImporterStub}]
               )

      assert imported_source.status == :fetched
      assert imported_source.campfire_id == "meetup-789"

      assert imported_source.resolved_url ==
               "https://campfire.nianticlabs.com/discover/meetups/meetup-789"

      assert %MapPoint{} = point = Repo.get_by!(MapPoint, map_source_id: source.id)
      assert point.title == "Evening Meetup"
      assert point.group_name == "City Raiders"

      refreshed_map = Repo.get!(CATools.Maps.UserMap, map.id)
      assert refreshed_map.points_count == 1
      assert %DateTime{} = refreshed_map.last_imported_at
    end
  end
end
