defmodule CAToolsWeb.Auth.UserRegistrationControllerTest do
  use CAToolsWeb.ConnCase, async: true

  import CATools.AccountsFixtures

  describe "GET /auth/users/register" do
    test "renders registration page", %{conn: conn} do
      conn = get(conn, ~p"/auth/users/register")
      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ ~p"/auth/users/log-in"
      assert response =~ ~p"/auth/users/register"
    end

    test "redirects if already logged in", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/auth/users/register")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /auth/users/register" do
    @tag :capture_log
    test "creates account but does not log in", %{conn: conn} do
      email = unique_user_email()

      conn =
        post(conn, ~p"/auth/users/register", %{
          "user" => valid_user_attributes(email: email)
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/auth/users/log-in"

      assert conn.assigns.flash["info"] =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end

    test "render errors for invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/users/register", %{
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ "must have the @ sign and no spaces"
    end
  end
end
