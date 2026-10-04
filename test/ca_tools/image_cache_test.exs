defmodule CATools.ImageCacheTest do
  use CATools.DataCase, async: true
  @moduletag :capture_log
  alias CATools.Maps.ImageCache
  use Oban.Testing, repo: CATools.Repo

  test "one download per URL is reused and served locally" do
    url = "https://cdn.example.com/#{System.unique_integer([:positive])}.png"

    body =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII="
      )

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :download)
      Plug.Conn.send_resp(conn, 200, body)
    end)

    opts = [
      dns_lookup: fn _ -> {:ok, [{1, 1, 1, 1}]} end,
      request_options: [plug: {Req.Test, __MODULE__}]
    ]

    assert :ok = ImageCache.fetch(url, opts)
    assert_received :download
    assert :ok = ImageCache.fetch(url, opts)
    refute_received :download
    assert {:ok, path, "image/webp"} = ImageCache.file(ImageCache.key(url))
    assert {:ok, processed} = CATools.Maps.ImageProcessor.process(body)
    assert File.read!(path) == processed
    assert ImageCache.local_urls([url])[url] == "/media/meetups/#{ImageCache.key(url)}?v=2"
  end

  test "redirects cache the original and destination with one request per URL" do
    nonce = System.unique_integer([:positive])
    origin = "https://cdn.example.com/origin-#{nonce}"
    target = "https://storage.example.com/target-#{nonce}.png"

    body =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII="
      )

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:download, conn.host})

      if conn.host == "cdn.example.com",
        do: conn |> Plug.Conn.put_resp_header("location", target) |> Plug.Conn.send_resp(307, ""),
        else: Plug.Conn.send_resp(conn, 200, body)
    end)

    opts = [
      dns_lookup: fn _ -> {:ok, [{1, 1, 1, 1}]} end,
      request_options: [plug: {Req.Test, __MODULE__}]
    ]

    ImageCache.fetch(origin, opts)
    assert_received {:download, "cdn.example.com"}
    assert_received {:download, "storage.example.com"}
    assert {:ok, path, "image/webp"} = ImageCache.file(ImageCache.key(origin))
    assert {:ok, processed} = CATools.Maps.ImageProcessor.process(body)
    assert File.read!(path) == processed
    ImageCache.fetch(origin, opts)
    ImageCache.fetch(target, opts)
    refute_received {:download, _}

    # A new meetup can reuse a redirected URL after both copies have expired.
    for url <- [origin, target] do
      cached = CATools.Repo.get!(CATools.Maps.CachedImage, ImageCache.key(url))

      cached
      |> Ecto.Changeset.change(status: "expired", content_type: nil)
      |> CATools.Repo.update!()

      File.rm!(Path.join(ImageCache.directory(), cached.id))
    end

    ImageCache.fetch(origin, opts)
    assert_received {:download, "cdn.example.com"}
    assert_received {:download, "storage.example.com"}
    assert {:ok, _, "image/webp"} = ImageCache.file(ImageCache.key(origin))
  end

  test "redirects to private hosts are blocked and failures have visible reasons" do
    url = "https://cdn.example.com/#{System.unique_integer([:positive])}"

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:download, conn.host})

      conn
      |> Plug.Conn.put_resp_header("location", "https://localhost/private.png")
      |> Plug.Conn.send_resp(307, "")
    end)

    opts = [
      dns_lookup: fn host ->
        {:ok, [if(host == "localhost", do: {127, 0, 0, 1}, else: {1, 1, 1, 1})]}
      end,
      request_options: [plug: {Req.Test, __MODULE__}]
    ]

    ImageCache.fetch(url, opts)
    assert_received {:download, "cdn.example.com"}
    refute_received {:download, "localhost"}
    summary = ImageCache.summary([%CATools.Maps.MapPoint{cover_photo_url: url}])
    assert summary.failed == 1
    assert summary.pending == 0
    assert summary.saved == 0
    assert summary.errors == ["Redirect destination could not be cached."]
  end

  test "only the owner can retry failed images and saved files are retained" do
    scope = CATools.AccountsFixtures.user_scope_fixture()
    map = CATools.MapsFixtures.map_fixture(scope)
    url = "https://cdn.example.com/#{System.unique_integer([:positive])}.png"

    CATools.Repo.insert!(%CATools.Maps.MapPoint{
      map_id: map.id,
      map_source_id: hd(map.sources).id,
      latitude: 3.0,
      longitude: 101.0,
      title: "Meetup",
      cover_photo_url: url
    })

    CATools.Repo.insert!(%CATools.Maps.CachedImage{
      id: ImageCache.key(url),
      status: "failed",
      attempted_at: DateTime.utc_now(:second)
    })

    assert {:error, :not_found} =
             ImageCache.retry_failed(CATools.AccountsFixtures.user_scope_fixture(), map.id)

    assert {:ok, 1} = ImageCache.retry_failed(scope, map.id)
    assert {:ok, 0} = ImageCache.retry_failed(scope, map.id)

    CATools.Repo.insert!(%CATools.Maps.CachedImage{
      id: ImageCache.key(url),
      status: "saved",
      content_type: "image/png",
      attempted_at: DateTime.utc_now(:second)
    })

    assert {:ok, 0} = ImageCache.retry_failed(scope, map.id)

    assert CATools.Repo.get!(CATools.Maps.CachedImage, ImageCache.key(url)).content_type ==
             "image/png"
  end

  test "oversized responses are rejected and are not requested again" do
    url = "https://cdn.example.com/#{System.unique_integer([:positive])}.png"

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :large_download)

      Plug.Conn.send_resp(
        conn,
        200,
        <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy(<<0>>, 5_000_000)
      )
    end)

    opts = [
      dns_lookup: fn _ -> {:ok, [{1, 1, 1, 1}]} end,
      request_options: [plug: {Req.Test, __MODULE__}]
    ]

    ImageCache.fetch(url, opts)
    assert_received :large_download
    assert ImageCache.file(ImageCache.key(url)) == :error
    ImageCache.fetch(url, opts)
    refute_received :large_download
  end

  test "failed downloads and unsafe destinations are not retried" do
    for status <- [500, 200] do
      url = "https://cdn.example.com/#{System.unique_integer([:positive])}.png"

      Req.Test.stub(__MODULE__, fn conn ->
        send(self(), :download)

        conn
        |> Plug.Conn.put_resp_header("location", "https://other.example.com/image.png")
        |> Plug.Conn.send_resp(status, "not an image")
      end)

      opts = [
        dns_lookup: fn _ -> {:ok, [{1, 1, 1, 1}]} end,
        request_options: [plug: {Req.Test, __MODULE__}]
      ]

      ImageCache.fetch(url, opts)
      assert_received :download
      ImageCache.fetch(url, opts)
      refute_received :download
      assert ImageCache.file(ImageCache.key(url)) == :error
      assert ImageCache.local_urls([url])[url] == nil
    end

    url = "https://localhost/private.png"
    ImageCache.fetch(url, dns_lookup: fn _ -> {:ok, [{127, 0, 0, 1}]} end)
    assert ImageCache.file(ImageCache.key(url)) == :error
    assert ImageCache.file("../secret") == :error
  end

  test "cleanup expires old meetup images while protecting shared images, logos and map uploads" do
    scope = CATools.AccountsFixtures.user_scope_fixture()
    map = CATools.MapsFixtures.map_fixture(scope)
    now = DateTime.utc_now(:second)
    old = DateTime.add(now, -31 * 86_400, :second)
    nonce = System.unique_integer([:positive])

    urls =
      for name <- ["old", "shared", "logo", "upload", "unknown", "boundary"],
          do: "https://cdn.example.com/#{name}-#{nonce}.png"

    [expired, shared, logo, upload, unknown, boundary] = urls

    Enum.each(Enum.with_index(urls), fn {url, index} ->
      map = CATools.MapsFixtures.map_fixture(scope)

      CATools.Repo.insert!(%CATools.Maps.MapPoint{
        map_id: map.id,
        map_source_id: hd(map.sources).id,
        title: "Meetup",
        latitude: 3.0,
        longitude: 101.0,
        cover_photo_url: url,
        ends_at:
          case index do
            4 -> nil
            5 -> DateTime.add(now, -30 * 86_400, :second)
            _ -> old
          end
      })

      id = ImageCache.key(url)

      CATools.Repo.insert!(%CATools.Maps.CachedImage{
        id: id,
        status: "saved",
        content_type: "image/webp",
        attempted_at: old
      })

      File.mkdir_p!(ImageCache.directory())
      File.write!(Path.join(ImageCache.directory(), id), "stored")
    end)

    new_map = CATools.MapsFixtures.map_fixture(scope)

    CATools.Repo.insert!(%CATools.Maps.MapPoint{
      map_id: new_map.id,
      map_source_id: hd(new_map.sources).id,
      title: "New meetup",
      latitude: 3.0,
      longitude: 101.0,
      host_avatar_url: shared,
      ends_at: now
    })

    CATools.Repo.insert!(%CATools.Communities.Community{
      user_id: scope.user.id,
      source_url: "https://example.com/#{nonce}",
      avatar_url: logo
    })

    map |> Ecto.Changeset.change(image_id: ImageCache.key(upload)) |> CATools.Repo.update!()

    assert ImageCache.prune(now) == 1
    assert ImageCache.file(ImageCache.key(expired)) == :error

    assert CATools.Repo.get!(CATools.Maps.CachedImage, ImageCache.key(expired)).status ==
             "expired"

    for url <- [shared, logo, upload, unknown, boundary],
        do: assert(match?({:ok, _, _}, ImageCache.file(ImageCache.key(url))))

    ImageCache.enqueue([expired])
    refute_enqueued(worker: CATools.Campfire.ImageCacheJob, args: %{"url" => expired})
    assert :ok = ImageCache.fetch(expired)

    assert ImageCache.summary([%CATools.Maps.MapPoint{cover_photo_url: expired, ends_at: old}]).total ==
             0

    reused_map = CATools.MapsFixtures.map_fixture(scope)

    CATools.Repo.insert!(%CATools.Maps.MapPoint{
      map_id: reused_map.id,
      map_source_id: hd(reused_map.sources).id,
      title: "Reused image",
      latitude: 3.0,
      longitude: 101.0,
      cover_photo_url: expired,
      ends_at: now
    })

    ImageCache.enqueue([expired])
    assert_enqueued(worker: CATools.Campfire.ImageCacheJob, args: %{"url" => expired})
  end

  test "existing originals are converted locally and receive a versioned URL" do
    url = "https://cdn.example.com/legacy-#{System.unique_integer([:positive])}.png"
    id = ImageCache.key(url)
    {:ok, image} = Vix.Vips.Operation.black(900, 600, bands: 3)
    {:ok, png} = Vix.Vips.Image.write_to_buffer(image, ".png")

    CATools.Repo.insert!(%CATools.Maps.CachedImage{
      id: id,
      status: "saved",
      content_type: "image/png",
      attempted_at: DateTime.utc_now(:second)
    })

    File.mkdir_p!(ImageCache.directory())
    File.write!(Path.join(ImageCache.directory(), id), png)

    assert ImageCache.process_existing() == 1
    assert {:ok, path, "image/webp"} = ImageCache.file(id)
    assert {:ok, decoded} = Vix.Vips.Image.new_from_file(path)
    assert Vix.Vips.Image.width(decoded) == 500
    assert Vix.Vips.Image.height(decoded) == 333
    assert ImageCache.local_urls([url])[url] == "/media/meetups/#{id}?v=2"
    assert ImageCache.process_existing() == 0
  end

  test "upgrades fetch the original once and preserve the existing file if the request fails" do
    scope = CATools.AccountsFixtures.user_scope_fixture()
    {:ok, original} = Vix.Vips.Operation.black(1000, 600, bands: 3)
    {:ok, png} = Vix.Vips.Image.write_to_buffer(original, ".png")
    {:ok, old} = Vix.Vips.Operation.black(300, 180, bands: 3)
    {:ok, old_body} = Vix.Vips.Image.write_to_buffer(old, ".webp")

    urls =
      for suffix <- ["success", "failure"],
          do:
            "https://cdn.example.com/upgrade-#{suffix}-#{System.unique_integer([:positive])}.png"

    for url <- urls do
      map = CATools.MapsFixtures.map_fixture(scope)

      CATools.Repo.insert!(%CATools.Maps.MapPoint{
        map_id: map.id,
        map_source_id: hd(map.sources).id,
        title: "Upgrade",
        cover_photo_url: url,
        latitude: 3.0,
        longitude: 101.0
      })

      id = ImageCache.key(url)

      CATools.Repo.insert!(%CATools.Maps.CachedImage{
        id: id,
        status: "saved",
        content_type: "image/webp",
        processing_version: 1,
        attempted_at: DateTime.utc_now(:second),
        bytes: byte_size(old_body)
      })

      File.mkdir_p!(ImageCache.directory())
      File.write!(Path.join(ImageCache.directory(), id), old_body)
    end

    [success, failure] = urls

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:upgrade, conn.request_path})

      Plug.Conn.send_resp(
        conn,
        if(String.contains?(conn.request_path, "failure"), do: 500, else: 200),
        png
      )
    end)

    opts = [
      dns_lookup: fn _ -> {:ok, [{1, 1, 1, 1}]} end,
      request_options: [plug: {Req.Test, __MODULE__}]
    ]

    assert ImageCache.process_existing(20, opts) == 2
    assert_received {:upgrade, _}
    assert_received {:upgrade, _}
    assert {:ok, path, "image/webp"} = ImageCache.file(ImageCache.key(success))
    assert {:ok, image} = Vix.Vips.Image.new_from_file(path)
    assert Vix.Vips.Image.width(image) == 500
    assert Vix.Vips.Image.height(image) == 300
    assert File.stat!(path).size <= 100_000

    assert ImageCache.local_urls([success])[success] ==
             "/media/meetups/#{ImageCache.key(success)}?v=2"

    assert {:ok, old_path, "image/webp"} = ImageCache.file(ImageCache.key(failure))
    assert File.read!(old_path) == old_body

    assert ImageCache.local_urls([failure])[failure] ==
             "/media/meetups/#{ImageCache.key(failure)}?v=1"

    assert ImageCache.process_existing(20, opts) == 0
    refute_received {:upgrade, _}
  end
end
