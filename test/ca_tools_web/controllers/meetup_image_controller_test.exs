defmodule CAToolsWeb.MeetupImageControllerTest do
  use CAToolsWeb.ConnCase, async: true

  test "cached image requests serve local bytes and missing files return 404", %{conn: conn} do
    id =
      CATools.Maps.ImageCache.key(
        "https://cdn.example.com/#{System.unique_integer([:positive])}.png"
      )

    CATools.Repo.insert!(%CATools.Maps.CachedImage{
      id: id,
      content_type: "image/png",
      attempted_at: DateTime.utc_now(:second)
    })

    File.mkdir_p!(CATools.Maps.ImageCache.directory())
    File.write!(Path.join(CATools.Maps.ImageCache.directory(), id), <<137, 80, 78, 71>>)
    response = get(conn, ~p"/media/meetups/#{id}")
    assert response(response, 200) == <<137, 80, 78, 71>>
    assert get_resp_header(response, "cache-control") == ["public, max-age=31536000, immutable"]

    assert response(get(conn, ~p"/media/meetups/#{String.duplicate("a", 64)}"), 404) ==
             "Image not found"
  end
end
