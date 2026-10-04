defmodule CAToolsWeb.AccountAccessTest do
  use CAToolsWeb.ConnCase, async: false
  import CATools.AccountsFixtures
  import Phoenix.LiveViewTest
  alias CATools.{Accounts, Repo}

  defmodule FailingMailer do
    use Swoosh.Adapter
    @impl true
    def deliver(_email, _config), do: {:error, :smtp_unavailable}
  end

  setup do
    old = Application.fetch_env!(:ca_tools, :public_signup_enabled)
    Application.put_env(:ca_tools, :public_signup_enabled, false)
    on_exit(fn -> Application.put_env(:ca_tools, :public_signup_enabled, old) end)
    :ok
  end

  test "public registration cannot create accounts", %{conn: conn} do
    email = unique_user_email()

    conn =
      post(conn, ~p"/auth/users/register", user: %{email: email, password: valid_user_password()})

    assert response(conn, 403) =~ "disabled"
    assert Accounts.get_user_by_email(email) == nil

    assert {:error, {:redirect, %{to: "/auth/users/log-in"}}} =
             live(build_conn(), ~p"/auth/users/register")

    {:ok, _, html} = live(build_conn(), ~p"/auth/users/log-in")
    refute html =~ "/auth/users/register"
  end

  test "regular users see their own settings and cannot access accounts or change the shared token",
       %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    assert get(conn, ~p"/dashboard/users").status == 403

    assert {:error, {:redirect, %{to: "/"}}} =
             live_isolated(conn, CAToolsWeb.Admin.Users,
               session: %{"user_token" => get_session(conn, :user_token)}
             )

    {:ok, lv, html} = live(conn, ~p"/auth/users/settings")
    refute html =~ "/dashboard/users"
    refute html =~ "campfire_credentials_form"
    assert html =~ "Delete your account"

    render_hook(lv, "submit_campfire_credentials", %{
      "campfire_credentials" => %{"campfire_token_input" => "stolen-token"},
      "intent" => "save"
    })

    assert Repo.get!(Accounts.User, user.id).encrypted_credentials == nil
  end

  test "signed-in navigation shares a live session", %{
    conn: conn
  } do
    conn = log_in_user(conn, admin_user_fixture())
    {:ok, view, _} = live(conn, ~p"/dashboard/community")

    for path <- [
          ~p"/dashboard/maps",
          ~p"/dashboard/users",
          ~p"/auth/users/settings",
          ~p"/dashboard/community"
        ] do
      route = Phoenix.Router.route_info(CAToolsWeb.Router, "GET", path, "localhost")
      assert {_, _, _, %{name: :authenticated_maps}} = route.phoenix_live_view
    end

    {:ok, accounts, _} =
      view
      |> element("a[href='/dashboard/users']")
      |> render_click()
      |> follow_redirect(conn, ~p"/dashboard/users")

    {:ok, settings, html} =
      accounts
      |> element("a[href='/auth/users/settings']")
      |> render_click()
      |> follow_redirect(conn, ~p"/auth/users/settings")

    assert html =~ "Settings"

    assert {:ok, _, _} =
             settings
             |> element("a.nav-link[href='/dashboard/community']")
             |> render_click()
             |> follow_redirect(conn, ~p"/dashboard/community")
  end

  test "admin creates a user by email and new user sets their password", %{conn: conn} do
    conn = log_in_user(conn, admin_user_fixture())
    {:ok, lv, html} = live(conn, ~p"/dashboard/users")
    assert html =~ "choose their own password"
    email = unique_user_email()
    html = lv |> form("#create-user-form", user: %{email: email}) |> render_submit()
    assert html =~ "An email to set their password has been sent"
    refute html =~ "Temporary password"
    assert_receive {:email, %Swoosh.Email{subject: "Set up your Pogo Meetups account"} = mail}
    [_, path] = Regex.run(~r{https?://[^/]+(/auth/users/reset-password/[^\s]+)}, mail.text_body)
    {:ok, _, html} = live(build_conn(), path)
    assert html =~ "Set your password"

    conn =
      post(build_conn(), path,
        user: %{password: valid_user_password(), password_confirmation: valid_user_password()}
      )

    assert redirected_to(conn) == ~p"/auth/users/log-in"
    assert Accounts.get_user_by_email_and_password(email, valid_user_password())
    # The already-consumed link cannot set another password.
    conn = post(build_conn(), path, user: %{password: "different secure password"})
    assert redirected_to(conn) == ~p"/auth/users/reset-password"
  end

  test "delete endpoint requires recent authentication and ignores any other account ID", %{
    conn: conn
  } do
    user = user_fixture()
    other = user_fixture()

    stale =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
      )

    assert redirected_to(delete(stale, ~p"/auth/users/account", account: %{email: user.email})) ==
             ~p"/auth/users/log-in"

    assert Repo.get!(Accounts.User, user.id)
    fresh = log_in_user(build_conn(), user)
    conn = delete(fresh, ~p"/auth/users/account", account: %{email: user.email, id: other.id})
    assert redirected_to(conn) == ~p"/"
    assert Repo.get(Accounts.User, user.id) == nil
    assert Repo.get!(Accounts.User, other.id)
  end

  test "failed setup email rolls back the new user and token" do
    scope = user_scope_fixture(admin_user_fixture())
    old = Application.fetch_env!(:ca_tools, CATools.Mailer)
    Application.put_env(:ca_tools, CATools.Mailer, adapter: FailingMailer)
    on_exit(fn -> Application.put_env(:ca_tools, CATools.Mailer, old) end)
    email = unique_user_email()

    assert {:error, {:email_delivery, :smtp_unavailable}} =
             Accounts.create_user(scope, %{email: email}, &"https://example.com/#{&1}")

    assert Accounts.get_user_by_email(email) == nil
    import Ecto.Query
    refute Repo.exists?(from t in Accounts.UserToken, where: t.sent_to == ^email)
  end
end
