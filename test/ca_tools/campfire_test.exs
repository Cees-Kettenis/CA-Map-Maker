defmodule CATools.CampfireTest do
  use CATools.DataCase, async: true

  alias CATools.Accounts
  alias CATools.Campfire.{DataNormalizer, GraphQLClient, Importer, ImportJob, LinkResolver}
  alias CATools.Maps.MapPoint
  alias CATools.Repo

  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  use Oban.Testing, repo: CATools.Repo

  describe "LinkResolver.resolve_source_url/2" do
    test "accepts the singular discover meetup path used by campfire-tools" do
      assert {:ok, %{campfire_id: "event-123", resource_type: :meetup}} =
               LinkResolver.extract_resource_from_url(
                 "https://campfire.nianticlabs.com/discover/meetup/event-123"
               )
    end

    test "resolves a public map object to its authenticated event ID" do
      Req.Test.stub(__MODULE__.PublicResolverStub, fn conn ->
        case {conn.host, conn.request_path} do
          {"cmpf.re", "/public123"} ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "https://niantic-social.nianticlabs.com/public/meetup/map-object-123"
            )
            |> Plug.Conn.resp(302, "")

          {"niantic-social.nianticlabs.com", "/public/meetup/map-object-123"} ->
            Plug.Conn.resp(conn, 200, "")

          {"niantic-social-api.nianticlabs.com", "/public/graphql"} ->
            assert Plug.Conn.get_req_header(conn, "authorization") == []
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["variables"] == %{"ids" => ["map-object-123"]}

            Req.Test.json(conn, %{
              "data" => %{
                "publicMapObjectsById" => [
                  %{"id" => "map-object-123", "event" => %{"id" => "event-456"}}
                ]
              }
            })
        end
      end)

      assert {:ok, source} =
               LinkResolver.resolve_source_url("https://cmpf.re/public123",
                 request_options: [plug: {Req.Test, __MODULE__.PublicResolverStub}]
               )

      assert source.campfire_id == "event-456"

      assert source.resolved_url ==
               "https://niantic-social.nianticlabs.com/public/meetup/map-object-123"
    end

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

    test "rejects private IPv4, IPv6 and mapped IPv4 destinations before requesting" do
      for address <- [
            {127, 0, 0, 1},
            {10, 0, 0, 1},
            {192, 168, 1, 1},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {64800, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 65535, 32512, 1}
          ] do
        assert {:error, %{code: "ssrf_blocked"}} =
                 LinkResolver.resolve_source_url("https://cmpf.re/private",
                   dns_lookup: fn _ -> {:ok, [address]} end
                 )
      end
    end

    test "limits redirect chains and rejects missing locations" do
      Req.Test.stub(__MODULE__.LoopStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://cmpf.re/loop")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, %{code: "redirect_limit_exceeded"}} =
               LinkResolver.resolve_source_url("https://cmpf.re/loop",
                 redirect_limit: 2,
                 dns_lookup: fn _ -> {:ok, [{8, 8, 8, 8}]} end,
                 request_options: [plug: {Req.Test, __MODULE__.LoopStub}]
               )

      Req.Test.stub(__MODULE__.LoopStub, &Plug.Conn.resp(&1, 302, ""))

      assert {:error, %{code: "missing_location"}} =
               LinkResolver.resolve_source_url("https://cmpf.re/loop",
                 dns_lookup: fn _ -> {:ok, [{8, 8, 8, 8}]} end,
                 request_options: [plug: {Req.Test, __MODULE__.LoopStub}]
               )
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
        admin_user_fixture()
        |> then(fn user ->
          {:ok, updated_user} =
            Accounts.update_user_campfire_token(user, %{
              "campfire_token_input" => "campfire-token"
            })

          updated_user
        end)

      Req.Test.stub(__MODULE__.GraphQLStub, fn conn ->
        assert ["Bearer campfire-token"] == Plug.Conn.get_req_header(conn, "authorization")
        assert conn.host == "niantic-social-api.nianticlabs.com"
        assert conn.request_path == "/graphql"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        assert request["variables"] == %{"id" => "meetup-123"}
        assert request["operationName"] == "CampfireMapSource"
        assert request["query"] == GraphQLClient.resource_query()
        assert request["query"] =~ "event(id: $id)"
        assert request["query"] =~ "coverPhotoUrl"
        assert request["query"] =~ "creator {"
        assert request["query"] =~ "displayName"
        assert request["query"] =~ "avatarUrl"
        refute request["query"] =~ "node(id:"

        Req.Test.json(conn, %{
          "data" => %{
            "event" => %{
              "id" => "meetup-123",
              "name" => "Community Raid Hour",
              "details" => "Local meetup",
              "eventTime" => "2026-06-02T10:00:00Z",
              "eventEndTime" => "2026-06-02T11:00:00Z",
              "address" => "Kuala Lumpur",
              "location" => "[101.6869,3.139]",
              "club" => %{"name" => "Downtown Raiders"}
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
      assert resource.resource["name"] == "Community Raid Hour"
    end

    test "returns graphql errors from the response body" do
      user =
        admin_user_fixture()
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

  describe "GraphQL response failures" do
    test "handles rejected tokens, null events and mismatched IDs" do
      user = admin_user_fixture()

      {:ok, user} =
        Accounts.update_user_campfire_token(user, %{"campfire_token_input" => "saved-token"})

      source = %{
        resolved_url: "https://campfire.nianticlabs.com/discover/meetup/event-123",
        campfire_id: "event-123",
        resource_type: :meetup
      }

      for {status, body, code} <- [
            {401, %{}, "unauthorized"},
            {403, %{}, "forbidden"},
            {200, %{"data" => %{"event" => nil}}, "missing_resource"},
            {200, %{"data" => %{"event" => %{"id" => "other"}}}, "missing_resource"},
            {200, %{"broken" => true}, "invalid_response"}
          ] do
        Req.Test.stub(__MODULE__.FailureStub, fn conn ->
          Req.Test.json(%{conn | status: status}, body)
        end)

        assert {:error, %{code: ^code}} =
                 GraphQLClient.fetch_resource(user, source,
                   request_options: [plug: {Req.Test, __MODULE__.FailureStub}]
                 )
      end

      Req.Test.stub(__MODULE__.FailureStub, fn conn ->
        Req.Test.json(conn, %{"errors" => [%{"message" => "Rejected saved-token"}]})
      end)

      assert {:error, error} =
               GraphQLClient.fetch_resource(user, source,
                 request_options: [plug: {Req.Test, __MODULE__.FailureStub}]
               )

      refute error.message =~ "saved-token"
    end
  end

  describe "DataNormalizer.normalize_map_point/2" do
    test "parses longitude first in JSON and comma-separated locations" do
      for location <- ["[101.6869, 3.139]", "101.6869,3.139", "(101.6869, 3.139)"] do
        assert {:ok, attrs} =
                 DataNormalizer.normalize_map_point(
                   %{
                     campfire_id: "event-123",
                     resource_type: :event,
                     resource: %{"name" => "Meetup", "location" => location}
                   },
                   %{
                     campfire_id: "event-123",
                     resource_type: :event,
                     resolved_url: "https://campfire.nianticlabs.com/discover/events/event-123"
                   }
                 )

        assert attrs.latitude == 3.139
        assert attrs.longitude == 101.6869
        assert attrs.group_name == nil
      end
    end

    test "cover photo URLs are normalized and unsafe or absent URLs are omitted" do
      for {url, expected} <- [
            {" https://cdn.example.com/cover.jpg ", "https://cdn.example.com/cover.jpg"},
            {nil, nil},
            {"", nil},
            {"javascript:alert(1)", nil},
            {"data:image/svg+xml,bad", nil},
            {"https://user:password@example.com/cover.jpg", nil}
          ] do
        assert {:ok, attrs} =
                 DataNormalizer.normalize_map_point(
                   %{
                     campfire_id: "event",
                     resource_type: :event,
                     resource: %{
                       "name" => "Meetup",
                       "location" => "[101,3]",
                       "coverPhotoUrl" => url
                     }
                   },
                   %{
                     campfire_id: "event",
                     resource_type: :event,
                     resolved_url: "https://campfire.nianticlabs.com/discover/events/event"
                   }
                 )

        assert attrs.cover_photo_url == expected
      end
    end

    test "host name falls back to username and profile pictures use safe URLs" do
      for {creator, name, avatar} <- [
            {%{
               "displayName" => "  Host Name  ",
               "username" => "username",
               "avatarUrl" => "https://cdn.example.com/avatar.jpg"
             }, "Host Name", "https://cdn.example.com/avatar.jpg"},
            {%{
               "displayName" => " ",
               "username" => "trainer",
               "avatarUrl" => "javascript:alert(1)"
             }, "trainer", nil},
            {nil, nil, nil},
            {"invalid", nil, nil}
          ] do
        assert {:ok, attrs} =
                 DataNormalizer.normalize_map_point(
                   %{
                     campfire_id: "event",
                     resource_type: :event,
                     resource: %{
                       "name" => "Meetup",
                       "location" => "[101,3]",
                       "creator" => creator
                     }
                   },
                   %{
                     campfire_id: "event",
                     resource_type: :event,
                     resolved_url: "https://campfire.nianticlabs.com/discover/events/event"
                   }
                 )

        assert attrs.host_name == name
        assert attrs.host_avatar_url == avatar
      end
    end

    test "rejects missing, malformed and out-of-range coordinates" do
      for location <- [nil, "", "bad", "[101,91]", "[181,3]", "[null,3]", "[3]"] do
        assert {:error, %{code: "missing_coordinates"}} =
                 DataNormalizer.normalize_map_point(
                   %{
                     campfire_id: "event-123",
                     resource_type: :event,
                     resource: %{"name" => "Meetup", "location" => location}
                   },
                   %{
                     campfire_id: "event-123",
                     resource_type: :event,
                     resolved_url: "https://campfire.nianticlabs.com/discover/events/event-123"
                   }
                 )
      end
    end

    test "normalizes a resource payload into map point attributes" do
      assert {:ok, attrs} =
               DataNormalizer.normalize_map_point(
                 %{
                   campfire_id: "meetup-123",
                   resource_type: :meetup,
                   resource: %{
                     "name" => "  Community Day  ",
                     "details" => "Meet at the park",
                     "eventTime" => "2026-06-02T10:00:00Z",
                     "eventEndTime" => "2026-06-02T11:00:00Z",
                     "address" => "Kuala Lumpur",
                     "location" => "[101.6869,3.139]",
                     "club" => %{"name" => "Trainers"}
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
    test "imports a source, updates counters and can reimport without duplicates" do
      user =
        admin_user_fixture()
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

          {"niantic-social-api.nianticlabs.com", "/graphql"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "event" => %{
                  "id" => "meetup-789",
                  "name" => "Evening Meetup",
                  "details" => "Bring lures",
                  "eventTime" => "2026-06-02T10:00:00.123Z",
                  "eventEndTime" => "2026-06-02T11:30:00Z",
                  "address" => "Central Park",
                  "location" => "[101.6869,3.139]",
                  "club" => %{"name" => "City Raiders"}
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

      Req.Test.stub(CATools.Campfire.ImportJobTestStub, fn conn ->
        case conn.request_path do
          "/import123" ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "https://campfire.nianticlabs.com/discover/meetup/meetup-789"
            )
            |> Plug.Conn.resp(302, "")

          "/discover/meetup/meetup-789" ->
            Plug.Conn.resp(conn, 200, "")

          "/graphql" ->
            Req.Test.json(conn, %{
              "data" => %{
                "event" => %{
                  "id" => "meetup-789",
                  "name" => "Updated Meetup",
                  "location" => "[101.6869,3.139]"
                }
              }
            })
        end
      end)

      assert point.starts_at == ~U[2026-06-02 10:00:00Z]

      assert {:ok, _} =
               Importer.import_source(source.id,
                 request_options: [plug: {Req.Test, CATools.Campfire.ImportJobTestStub}]
               )

      assert Repo.aggregate(MapPoint, :count) == 1
      assert Repo.get!(MapPoint, point.id).title == "Updated Meetup"
    end

    test "the worker cancels sources that no longer exist" do
      assert {:cancel, :not_found} = perform_job(ImportJob, %{"source_id" => -1})
    end
  end
end
