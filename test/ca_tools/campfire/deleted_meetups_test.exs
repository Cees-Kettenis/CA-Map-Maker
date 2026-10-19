defmodule CATools.Campfire.DeletedMeetupsTest do
  use CAToolsWeb.ConnCase, async: false
  use Oban.Testing, repo: CATools.Repo

  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CATools.{Accounts, Communities, Maps, MeetupMaps, Repo}
  alias CATools.Campfire.{CommunitySyncJob, GraphQLClient, ImportJob, MaintenanceJob}
  alias CATools.Maps.{ImportBatch, MapPoint, MapSource, UserMap}

  setup do
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
      Communities.save(scope, %{
        source_url: "https://campfire.nianticlabs.com/discover/clubs/group"
      })

    starts_at = DateTime.add(DateTime.utc_now(:second), 86_400)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body)["operationName"] do
        "ActiveEvents_Query" ->
          Req.Test.json(conn, %{
            data: %{
              club: %{
                id: "group",
                name: "Our group",
                activeFeed: %{
                  edges: [%{node: %{id: "event"}}],
                  pageInfo: %{hasNextPage: false, endCursor: nil}
                }
              }
            }
          })

        "CampfireMapSource" ->
          Req.Test.json(conn, %{
            data: %{
              event: %{
                id: "event",
                name: "Tomorrow's meetup",
                location: "[101.6869,3.139]",
                eventTime: DateTime.to_iso8601(starts_at),
                eventEndTime: DateTime.to_iso8601(DateTime.add(starts_at, 3600)),
                club: %{id: "group", name: "Our group"}
              }
            }
          })
      end
    end)

    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id})
    source = Repo.get_by!(MapSource, map_id: community.map_id)
    assert %{success: 1} = Oban.drain_queue(queue: :imports)

    %{scope: scope, community: community, source: source, starts_at: starts_at}
  end

  test "a deleted meetup leaves shared, pasted and date maps and an open page safely", %{
    conn: conn,
    scope: scope,
    community: community,
    source: source,
    starts_at: starts_at
  } do
    other_scope = user_scope_fixture()
    {:ok, shared} = Communities.save(other_scope, %{source_url: community.source_url})
    pasted_scope = user_scope_fixture()

    pasted = map_fixture(pasted_scope, %{"source_urls_input" => source.original_url})
    assert :ok = perform_job(ImportJob, %{source_id: hd(pasted.sources).id})

    {:ok, date_map} =
      MeetupMaps.create(scope, %{
        name: "Tomorrow",
        meetup_date: DateTime.to_date(starts_at),
        community_ids: [community.id]
      })

    assert length(date_map.points) == 1
    {:ok, view, _} = conn |> log_in_user(scope.user) |> live(~p"/dashboard/community")
    assert has_element?(view, "#community-meetups h3", "Tomorrow's meetup")

    unrelated = map_fixture(scope, %{"source_urls_input" => "https://cmpf.re/unrelated"})

    Repo.insert!(%MapPoint{
      map_id: unrelated.id,
      map_source_id: hd(unrelated.sources).id,
      campfire_id: "unrelated",
      title: "Another meetup",
      latitude: 3.139,
      longitude: 101.6869
    })

    Maps.subscribe(other_scope.user.id)
    Maps.subscribe(pasted_scope.user.id)
    Repo.delete_all(CATools.Campfire.ResponseCache)

    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{errors: [%{message: "event not found"}]})
    )

    assert {:cancel, :skipped} = perform_job(ImportJob, %{source_id: source.id, force: true})

    for {owner, map_id} <- [
          {scope, community.map_id},
          {other_scope, shared.map_id},
          {pasted_scope, pasted.id}
        ] do
      assert Maps.get_map(owner, map_id).points == []
      assert Repo.get!(UserMap, map_id).points_count == 0
      removed = Repo.get_by!(MapSource, map_id: map_id)
      assert removed.status == :skipped
      assert removed.error_code == "resource_removed"

      if removed.import_batch_id do
        assert Repo.get!(ImportBatch, removed.import_batch_id).processed_count == 1
      end
    end

    assert_receive :refresh
    assert_receive :refresh
    assert Maps.get_map(scope, date_map.id).points == []
    assert Repo.get_by!(MapPoint, map_id: unrelated.id).title == "Another meetup"
    refute has_element?(view, "#community-meetups h3", "Tomorrow's meetup")
    assert Process.alive?(view.pid)

    Req.Test.stub(__MODULE__, fn _conn -> flunk("A removed source was fetched again") end)
    assert {:cancel, :skipped} = perform_job(ImportJob, %{source_id: source.id, force: true})
  end

  test "group updates check a saved meetup even when the feed is empty", %{
    scope: scope,
    community: community,
    source: source
  } do
    Repo.delete_all(CATools.Campfire.ResponseCache)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        data: %{
          club: %{
            id: "group",
            name: "Our group",
            activeFeed: %{
              edges: [],
              pageInfo: %{hasNextPage: false, endCursor: nil}
            }
          }
        }
      })
    end)

    assert :ok = Communities.check_now(scope, community.id)
    # Production had already marked the removed event as a failed import.
    Repo.update_all(from(s in MapSource, where: s.id == ^source.id),
      set: [status: :failed, error_code: "graphql_error", error_message: "event not found"]
    )

    assert :ok = perform_job(CommunitySyncJob, %{community_id: community.id, force: true})
    assert Repo.get!(MapSource, source.id).status == :pending
    assert_enqueued(worker: ImportJob, args: %{source_id: source.id, force: true})
    assert length(Maps.get_map(scope, community.map_id).points) == 1

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{data: %{event: nil}}))
    assert {:cancel, :skipped} = perform_job(ImportJob, %{source_id: source.id, force: true})
    assert Maps.get_map(scope, community.map_id).points == []
  end

  test "daily maintenance checks saved meetups that disappear from discovery", %{
    source: source
  } do
    yesterday = DateTime.add(DateTime.utc_now(:second), -86_401)

    Repo.update_all(from(s in MapSource, where: s.id == ^source.id),
      set: [last_fetched_at: yesterday, updated_at: yesterday]
    )

    assert :ok = perform_job(MaintenanceJob, %{})
    assert Repo.get!(MapSource, source.id).status == :pending
  end

  test "failed and malformed responses preserve the saved meetup", %{source: source} do
    Repo.delete_all(CATools.Campfire.ResponseCache)

    for {status, body} <- [
          {401, %{}},
          {403, %{}},
          {404, %{}},
          {500, %{}},
          {200, %{data: %{event: nil}, errors: [%{message: "Access denied"}]}},
          {200, %{errors: [%{message: "event not found"}, %{message: "Access denied"}]}},
          {200, %{data: %{event: nil}, errors: [nil]}},
          {200, %{data: %{event: nil}, errors: "malformed"}},
          {200, %{data: %{event: %{id: "different"}}}},
          {200, %{data: %{}}},
          {200, %{broken: true}}
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(%{&1 | status: status}, body))
      assert {:error, _} = perform_job(ImportJob, %{source_id: source.id, force: true})
      assert Repo.get_by!(MapPoint, map_source_id: source.id).title == "Tomorrow's meetup"
      assert Repo.get!(UserMap, source.map_id).points_count == 1
    end

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, {"timeout", _}} = perform_job(ImportJob, %{source_id: source.id, force: true})
    assert Repo.get_by!(MapPoint, map_source_id: source.id).title == "Tomorrow's meetup"
  end

  test "cancelling an import during the request preserves its saved meetup", %{source: source} do
    Repo.delete_all(CATools.Campfire.ResponseCache)

    Req.Test.stub(__MODULE__, fn conn ->
      Repo.update_all(from(b in ImportBatch, where: b.id == ^source.import_batch_id),
        set: [status: :cancelled]
      )

      Req.Test.json(conn, %{data: %{event: nil}})
    end)

    perform_job(ImportJob, %{source_id: source.id, force: true})
    assert Repo.get_by!(MapPoint, map_source_id: source.id).title == "Tomorrow's meetup"
  end

  test "removing the map while a missing-meetup request is in flight is safe", %{
    scope: scope,
    source: source
  } do
    Repo.delete_all(CATools.Campfire.ResponseCache)

    Req.Test.stub(__MODULE__, fn conn ->
      assert {:ok, _} = Maps.delete_map(scope, source.map_id)
      Req.Test.json(conn, %{data: %{event: nil}})
    end)

    assert {:cancel, :not_found} = perform_job(ImportJob, %{source_id: source.id, force: true})
    refute Repo.get(MapSource, source.id)
  end
end
