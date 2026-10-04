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
    user = admin_user_fixture()

    {:ok, user} =
      Accounts.update_user_campfire_token(user, %{"campfire_token_input" => "test-token"})

    map =
      map_fixture(user_scope_fixture(user), %{
        "source_urls_input" => "https://campfire.nianticlabs.com/discover/meetup/event-123"
      })

    community =
      Repo.insert!(%CATools.Communities.Community{
        user_id: user.id,
        map_id: map.id,
        source_url: "https://campfire.nianticlabs.com/discover/clubs/city"
      })

    {:ok, linked_map} =
      CATools.MeetupMaps.create(user_scope_fixture(user), %{
        name: "Linked map",
        meetup_date: "2026-10-02",
        community_ids: [community.id]
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
                "coverPhotoUrl" => "https://cdn.example.com/cover.jpg",
                "creator" => %{
                  "displayName" => "Trainer Host",
                  "username" => "trainer",
                  "avatarUrl" => "https://cdn.example.com/avatar.jpg"
                },
                "location" => "[101.6869,3.139]",
                "club" => %{"id" => "city", "name" => "City Raiders"},
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
    assert point.cover_photo_url == "https://cdn.example.com/cover.jpg"
    assert point.host_name == "Trainer Host"
    assert point.host_avatar_url == "https://cdn.example.com/avatar.jpg"
    assert point.group_name == "City Raiders"
    assert point.club_id == "city"
    assert point.latitude == 3.139
    assert point.longitude == 101.6869
    assert point.starts_at == ~U[2026-10-02 10:00:00Z]
    batch = Repo.get!(ImportBatch, source.import_batch_id)
    assert batch.status == :completed
    assert batch.processed_count == 1
    assert batch.success_count == 1
    [linked_point] = CATools.Maps.get_map(user_scope_fixture(user), linked_map.id).points
    assert linked_point.title == "Raid Hour"
    assert linked_point.host_name == "Trainer Host"

    assert_enqueued(
      worker: CATools.Campfire.ImageCacheJob,
      args: %{url: "https://cdn.example.com/cover.jpg"}
    )

    assert_enqueued(
      worker: CATools.Campfire.ImageCacheJob,
      args: %{url: "https://cdn.example.com/avatar.jpg"}
    )

    body =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII="
      )

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:image_download, conn.host, conn.request_path})

      if conn.host == "cdn.example.com" do
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "https://storage.example.com#{conn.request_path}"
        )
        |> Plug.Conn.send_resp(307, "")
      else
        Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    for url <- [point.cover_photo_url, point.host_avatar_url] do
      assert :error = CATools.Maps.ImageCache.file(CATools.Maps.ImageCache.key(url))

      assert :ok =
               CATools.Maps.ImageCache.fetch(url,
                 require_reference: true,
                 dns_lookup: fn _ -> {:ok, [{1, 1, 1, 1}]} end,
                 request_options: [plug: {Req.Test, __MODULE__}]
               )

      path = URI.parse(url).path
      assert_received {:image_download, "cdn.example.com", ^path}
      assert_received {:image_download, "storage.example.com", ^path}

      assert {:ok, _, "image/webp"} =
               CATools.Maps.ImageCache.file(CATools.Maps.ImageCache.key(url))
    end

    [rendered] = CATools.Maps.point_data(CATools.Maps.get_map(user_scope_fixture(user), map.id))

    assert rendered.cover_photo_url ==
             "/media/meetups/#{CATools.Maps.ImageCache.key(point.cover_photo_url)}?v=2"

    assert rendered.host_avatar_url ==
             "/media/meetups/#{CATools.Maps.ImageCache.key(point.host_avatar_url)}?v=2"
  end

  test "different source links to the same event produce one marker" do
    user = admin_user_fixture()

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
