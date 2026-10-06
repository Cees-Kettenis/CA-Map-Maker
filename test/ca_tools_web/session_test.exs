defmodule CAToolsWeb.SessionTest do
  use CAToolsWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:ca_tools, :secure_cookies)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ca_tools, :secure_cookies)
      else
        Application.put_env(:ca_tools, :secure_cookies, previous)
      end
    end)
  end

  test "HTTPS deployments mark cookies secure even behind an HTTP upstream" do
    Application.put_env(:ca_tools, :secure_cookies, true)

    conn =
      Plug.Test.conn(:get, "http://localhost/")
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> CAToolsWeb.Endpoint.session([])
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session(:user_token, "test-session")
      |> Plug.Conn.send_resp(200, "ok")

    assert conn.resp_cookies["_ca_tools_key"].secure
    assert CAToolsWeb.Endpoint.session_options()[:secure]
  end

  test "HTTP deployments retain usable local sessions" do
    Application.put_env(:ca_tools, :secure_cookies, false)

    conn =
      Plug.Test.conn(:get, "http://localhost/")
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> CAToolsWeb.Endpoint.session([])
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session(:user_token, "test-session")
      |> Plug.Conn.send_resp(200, "ok")

    refute conn.resp_cookies["_ca_tools_key"].secure
    refute CAToolsWeb.Endpoint.session_options()[:secure]
  end

  test "HTTPS remember-me cookies and logout use the same secure policy", %{conn: conn} do
    Application.put_env(:ca_tools, :secure_cookies, true)
    user = CATools.AccountsFixtures.user_fixture()

    conn =
      conn
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.fetch_cookies()
      |> CAToolsWeb.Auth.UserAuth.log_in_user(user, %{"remember_me" => "true"})

    assert conn.resp_cookies["_ca_tools_web_user_remember_me"].secure

    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> Plug.Test.init_test_session(%{user_token: Plug.Conn.get_session(conn, :user_token)})
      |> Plug.Conn.fetch_cookies()
      |> CAToolsWeb.Auth.UserAuth.log_out_user()

    assert conn.resp_cookies["_ca_tools_web_user_remember_me"].secure
    assert conn.resp_cookies["_ca_tools_web_user_remember_me"].max_age == 0
  end
end
