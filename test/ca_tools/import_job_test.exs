defmodule CATools.Campfire.ImportJobTest do
  use CATools.DataCase, async: false

  alias CATools.Accounts
  alias CATools.Campfire.{GraphQLClient, ImportJob, LinkResolver}
  alias CATools.Maps.{ImportBatch, MapPoint, MapSource}

  import CATools.AccountsFixtures
  import CATools.MapsFixtures
  use Oban.Testing, repo: CATools.Repo

  setup do
    for module <- [GraphQLClient, LinkResolver] do
      original = Application.fetch_env!(:ca_tools, module)

      Application.put_env(
        :ca_tools,
        module,
        Keyword.put(original, :request_options, plug: {Req.Test, __MODULE__})
      )

      on_exit(fn -> Application.put_env(:ca_tools, module, original) end)
    end

    :ok
  end

  test "imports a saved source through the worker and stores Campfire event fields" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_user_campfire_token(user, %{"campfire_token_input" => "test-token"})

    map =
      map_fixture(user_scope_fixture(user), %{
        "source_urls_input" => "https://campfire.nianticlabs.com/discover/meetup/event-123"
      })

    [source] = map.sources

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/discover/meetup/event-123" ->
          Plug.Conn.resp(conn, 200, "")

        "/graphql" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

          Req.Test.json(conn, %{
            "data" => %{
              "event" => %{
                "id" => "event-123",
                "name" => "Raid Hour",
                "details" => "Meet at the park",
                "location" => "[101.6869,3.139]",
                "club" => %{"name" => "City Raiders"},
                "eventTime" => "2026-10-02T10:00:00.123Z"
              }
            }
          })
      end
    end)

    assert :ok = perform_job(ImportJob, %{"source_id" => source.id})
    assert Repo.get!(MapSource, source.id).status == :fetched
    point = Repo.get_by!(MapPoint, map_source_id: source.id)
    assert point.title == "Raid Hour"
    assert point.description == "Meet at the park"
    assert point.group_name == "City Raiders"
    assert point.latitude == 3.139
    assert point.longitude == 101.6869
    assert point.starts_at == ~U[2026-10-02 10:00:00Z]
    batch = Repo.get!(ImportBatch, source.import_batch_id)
    assert batch.status == :completed
    assert batch.processed_count == 1
    assert batch.success_count == 1
  end

  test "different source links to the same event produce one marker" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_user_campfire_token(user, %{"campfire_token_input" => "test-token"})

    map =
      map_fixture(user_scope_fixture(user), %{
        "source_urls_input" =>
          "https://campfire.nianticlabs.com/discover/meetup/same-event\n" <>
            "https://campfire.nianticlabs.com/discover/events/same-event"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "event" => %{
            "id" => "same-event",
            "name" => "One meetup",
            "location" => "[101.6869,3.139]"
          }
        }
      })
    end)

    [first, second] = Enum.sort_by(map.sources, & &1.id)
    assert :ok = perform_job(ImportJob, %{"source_id" => first.id})
    assert {:cancel, :skipped} = perform_job(ImportJob, %{"source_id" => second.id})
    assert Repo.get!(MapSource, second.id).error_code == "duplicate_event"
    assert Repo.aggregate(MapPoint, :count) == 1
    assert Repo.get!(ImportBatch, second.import_batch_id).processed_count == 2
  end

  test "records failed imports and returns an error so Oban retries" do
    map =
      map_fixture(user_scope_fixture(), %{
        "source_urls_input" => "https://campfire.nianticlabs.com/discover/meetup/event-123"
      })

    [source] = map.sources
    Req.Test.stub(__MODULE__, &Plug.Conn.resp(&1, 200, ""))

    assert {:error, {"missing_credentials", _message}} =
             perform_job(ImportJob, %{"source_id" => source.id})

    source = Repo.get!(MapSource, source.id)
    assert source.status == :failed
    assert source.error_code == "missing_credentials"
    assert source.attempts == 1
    assert Repo.aggregate(MapPoint, :count) == 0
  end
end
