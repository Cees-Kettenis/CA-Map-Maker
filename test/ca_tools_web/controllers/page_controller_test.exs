defmodule CAToolsWeb.PageControllerTest do
  use CAToolsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "Map your"
    assert html =~ "meetups"
  end
end
