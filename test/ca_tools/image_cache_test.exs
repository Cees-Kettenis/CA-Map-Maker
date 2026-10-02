defmodule CATools.ImageCacheTest do
  use CATools.DataCase, async: true
  @moduletag :capture_log
  alias CATools.Maps.ImageCache

  test "one download per URL is reused and served locally" do
    url = "https://cdn.example.com/#{System.unique_integer([:positive])}.png"
    body = <<137, 80, 78, 71, 13, 10, 26, 10, 0>>

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
    assert {:ok, path, "image/png"} = ImageCache.file(ImageCache.key(url))
    assert File.read!(path) == body
    assert ImageCache.local_urls([url])[url] == "/media/meetups/#{ImageCache.key(url)}"
  end

  test "redirects cache the original and destination with one request per URL" do
    nonce = System.unique_integer([:positive])
    origin = "https://cdn.example.com/origin-#{nonce}"
    target = "https://storage.example.com/target-#{nonce}.png"
    body = <<137, 80, 78, 71, 13, 10, 26, 10, 0>>

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
    assert {:ok, path, "image/png"} = ImageCache.file(ImageCache.key(origin))
    assert File.read!(path) == body
    ImageCache.fetch(origin, opts)
    ImageCache.fetch(target, opts)
    refute_received {:download, _}
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
end
