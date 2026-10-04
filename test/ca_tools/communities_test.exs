defmodule CATools.CommunitiesTest do
  use CATools.DataCase, async: false
  import CATools.AccountsFixtures
  import Ecto.Query
  use Oban.Testing, repo: CATools.Repo
  alias CATools.{Accounts, Communities, Maps, Repo}
  alias CATools.Campfire.{ClubResolver, CommunitySyncJob, GraphQLClient, MaintenanceJob}
  alias CATools.Communities.Community
  alias CATools.Maps.MapSource

  test "group and invitation links resolve the club ID without fetching a meetup" do
    for kind <- ["club", "clubs", "group", "groups"] do
      assert {:ok, "club-123"} =
               ClubResolver.resolve("https://campfire.nianticlabs.com/discover/#{kind}/club-123")
    end

    payload = Base.encode64("r=clubs&c=club-123")

    assert {:ok, "club-123"} =
             ClubResolver.resolve(
               "https://campfire.onelink.me/test?" <>
                 URI.encode_query(%{"deep_link_sub1" => payload})
             )

    assert {:error, _} =
             ClubResolver.club_id("https://campfire.onelink.me/test?deep_link_sub1=broken")

    assert {:error, _} = ClubResolver.validate_url("https://example.com/groups/foo")

    assert {:error, _} =
             ClubResolver.validate_url(
               "https://campfire.nianticlabs.com/discover/meetup/event-123"
             )

    assert {:error, _} = ClubResolver.validate_url("https://campfire.onelink.me:8080/test")
  end

  test "a short group invitation resolves through the guarded redirect resolver" do
    invitation =
      "https://campfire.onelink.me/test?" <>
        URI.encode_query(%{"deep_link_sub1" => Base.encode64("r=clubs&c=club-123")})

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", invitation) |> Plug.Conn.resp(302, "")
    end)

    assert {:ok, "club-123"} =
             ClubResolver.resolve("https://cmpf.re/group",
               request_options: [plug: {Req.Test, __MODULE__}],
               dns_lookup: fn _ -> {:ok, [{1, 1, 1, 1}]} end
             )

    assert {:error, %{code: "ssrf_blocked"}} =
             ClubResolver.resolve("https://cmpf.re/group",
               request_options: [plug: {Req.Test, __MODULE__}],
               dns_lookup: fn _ -> {:ok, [{127, 0, 0, 1}]} end
             )
  end

  test "saves a private map, scopes ownership, and queues a community check" do
    scope = user_scope_fixture()

    assert {:ok, community} =
             Communities.save(scope, %{
               source_url: "https://campfire.nianticlabs.com/discover/clubs/club-123"
             })

    assert Maps.get_map(scope, community.map_id).visibility == :private
    assert Communities.get(user_scope_fixture()) == nil
    assert_enqueued(worker: CommunitySyncJob, args: %{community_id: community.id})
    assert {:error, changeset} = Maps.update_map(scope, community.map_id, %{visibility: "public"})
    assert "Community maps use invitation-only sharing." in errors_on(changeset).visibility
  end

  test "only invited confirmed accounts can view a community map and revocation removes access" do
    scope = user_scope_fixture()

    {:ok, community} =
      Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/club-123"
      })

    invited = user_fixture()
    invited_scope = user_scope_fixture(invited)
    assert Communities.shared_map(invited_scope, community.map_id) == nil

    assert {:ok, invitation} =
             Communities.invite(scope, %{email: "  " <> String.upcase(invited.email) <> "  "})

    assert Communities.shared_map(invited_scope, community.map_id).id == community.map_id
    assert Communities.shared_map(nil, community.map_id) == nil
    assert Communities.shared_map(user_scope_fixture(), community.map_id) == nil
    unconfirmed = %{invited | confirmed_at: nil}
    assert Communities.shared_map(user_scope_fixture(unconfirmed), community.map_id) == nil
    Communities.revoke(user_scope_fixture(), invitation.id)
    assert Communities.shared_map(invited_scope, community.map_id)
    Communities.revoke(scope, invitation.id)
    assert Communities.shared_map(invited_scope, community.map_id) == nil

    assert Maps.get_public_map(Maps.get_map(scope, community.map_id).public_slug || "missing") ==
             nil
  end

  test "changing a group replaces its map and clears previous invitations" do
    scope = user_scope_fixture()

    {:ok, first} =
      Communities.save(scope, %{source_url: "https://campfire.nianticlabs.com/discover/clubs/one"})

    {:ok, _} = Communities.invite(scope, %{email: "guest@example.com"})

    {:ok, second} =
      Communities.save(scope, %{source_url: "https://campfire.nianticlabs.com/discover/clubs/two"})

    assert second.id == first.id
    refute second.map_id == first.map_id
    assert second.invitations == []
    assert Maps.get_map(scope, first.map_id) == nil
    assert {:error, _} = Communities.save(scope, %{source_url: "https://example.com/wrong"})
    assert Communities.get(scope).map_id == second.map_id
  end

  test "monitoring follows pagination, deduplicates discoveries, and respects the check interval" do
    original = Application.fetch_env!(:ca_tools, GraphQLClient)

    Application.put_env(
      :ca_tools,
      GraphQLClient,
      Keyword.put(original, :request_options, plug: {Req.Test, __MODULE__})
    )

    on_exit(fn -> Application.put_env(:ca_tools, GraphQLClient, original) end)
    scope = user_scope_fixture(admin_user_fixture())

    {:ok, user} =
      Accounts.update_user_campfire_token(scope.user, %{"campfire_token_input" => "test-token"})

    scope = user_scope_fixture(user)

    {:ok, community} =
      Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/club-123"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["operationName"] == "ActiveEvents_Query"
      assert request["variables"]["first"] == 100
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      assert request["query"] =~ "activeFeed(first: $first, after: $after)"
      more = request["variables"]["after"] == nil
      ids = if more, do: ["event-1", "event-1"], else: ["event-1", "event-2"]

      Req.Test.json(conn, %{
        data: %{
          club: %{
            id: "club-123",
            name: "City Raiders",
            avatarUrl: "https://cdn.example.com/group-icon.png",
            activeFeed: %{
              edges: Enum.map(ids, &%{node: %{id: &1}}),
              pageInfo: %{hasNextPage: more, endCursor: if(more, do: "next-page")}
            }
          }
        }
      })
    end)

    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    assert Communities.get(scope).cursor == nil

    assert DateTime.diff(
             Communities.get(scope).next_check_at,
             Communities.get(scope).last_checked_at
           ) == 86_400

    assert Communities.get(scope).avatar_url == "https://cdn.example.com/group-icon.png"

    assert_enqueued(
      worker: CATools.Campfire.ImageCacheJob,
      args: %{url: "https://cdn.example.com/group-icon.png"}
    )

    assert Maps.get_map(scope, community.map_id).sources_count == 2
    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    assert Repo.aggregate(MapSource, :count) == 2
    assert :ok = Communities.check_now(scope)
    assert Communities.get(scope).next_check_at == nil
    assert_enqueued(worker: CommunitySyncJob, args: %{community_id: community.id, force: true})
    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id, force: true})
    assert Maps.get_map(scope, community.map_id).name == "City Raiders"

    existing_source =
      Repo.get_by!(MapSource,
        map_id: community.map_id,
        original_url: "https://campfire.nianticlabs.com/discover/meetup/event-1"
      )

    Repo.update!(
      Ecto.Changeset.change(existing_source,
        status: :fetched,
        last_fetched_at: DateTime.add(DateTime.utc_now(:second), -86_401)
      )
    )

    Repo.update_all(from(c in Community, where: c.id == ^community.id), set: [next_check_at: nil])
    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    assert Repo.get!(MapSource, existing_source.id).status == :pending
    assert Repo.aggregate(MapSource, :count) == 2
  end

  test "a group change during discovery cannot add old-group meetups to the replacement map" do
    original = Application.fetch_env!(:ca_tools, GraphQLClient)

    Application.put_env(
      :ca_tools,
      GraphQLClient,
      Keyword.put(original, :request_options, plug: {Req.Test, __MODULE__})
    )

    on_exit(fn -> Application.put_env(:ca_tools, GraphQLClient, original) end)

    {:ok, user} =
      Accounts.update_user_campfire_token(admin_user_fixture(), %{
        "campfire_token_input" => "test-token"
      })

    scope = user_scope_fixture(user)

    {:ok, community} =
      Communities.save(scope, %{source_url: "https://campfire.nianticlabs.com/discover/clubs/old"})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _} =
        Communities.save(scope, %{
          source_url: "https://campfire.nianticlabs.com/discover/clubs/new"
        })

      Req.Test.json(conn, %{
        data: %{
          club: %{
            id: "old",
            name: "Old group",
            activeFeed: %{
              edges: [%{node: %{id: "old-event"}}],
              pageInfo: %{hasNextPage: false, endCursor: nil}
            }
          }
        }
      })
    end)

    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    current = Communities.get(scope)
    assert current.source_url =~ "/new"
    assert current.name == nil
    assert Maps.get_map(scope, current.map_id).sources_count == 0
    assert Repo.aggregate(MapSource, :count) == 0
  end

  test "saving unchanged settings preserves the check interval and deleting the map is safe" do
    scope = user_scope_fixture()

    {:ok, community} =
      Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/group"
      })

    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    due = Communities.get(scope).next_check_at
    {:ok, saved} = Communities.save(scope, %{source_url: community.source_url})
    assert saved.next_check_at == due
    {:ok, _} = Maps.delete_map(scope, community.map_id)
    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    {:ok, replacement} = Communities.save(scope, %{source_url: community.source_url})
    refute replacement.map_id == community.map_id
    assert replacement.next_check_at == nil
  end

  test "missing credentials are visible and maintenance schedules only enabled due communities" do
    scope = user_scope_fixture()

    {:ok, community} =
      Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/club-123"
      })

    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    assert Communities.get(scope).error_message =~ "no saved Campfire credentials"
    Repo.update_all(Community, set: [next_check_at: nil])
    assert :ok = perform_job(MaintenanceJob, %{})
    assert_enqueued(worker: CommunitySyncJob, args: %{community_id: community.id})
    {:ok, _} = Communities.save(scope, %{enabled: false})
    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    assert {:error, :disabled} = Communities.check_now(scope)
  end
end
