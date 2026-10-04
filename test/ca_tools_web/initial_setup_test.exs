defmodule CAToolsWeb.InitialSetupTest do
  use CAToolsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  alias CATools.{Accounts, Repo}
  alias CATools.Accounts.{User, UserToken}

  defmodule FailingMailer do
    use Swoosh.Adapter
    @impl true
    def deliver(_email, _config), do: {:error, :smtp_unavailable}
  end

  setup do
    setup_enabled = Application.fetch_env!(:ca_tools, :initial_setup_enabled)
    signup_enabled = Application.fetch_env!(:ca_tools, :public_signup_enabled)
    Application.put_env(:ca_tools, :initial_setup_enabled, true)
    Application.put_env(:ca_tools, :public_signup_enabled, false)

    on_exit(fn ->
      Application.put_env(:ca_tools, :initial_setup_enabled, setup_enabled)
      Application.put_env(:ca_tools, :public_signup_enabled, signup_enabled)
    end)

    :ok
  end

  test "fresh installation stays behind setup until the emailed password is chosen", %{conn: conn} do
    assert Accounts.installation_state() == :empty

    for path <- [
          "/",
          "/auth/users/log-in",
          "/dashboard/maps",
          "/dashboard/users",
          "/maps/missing/points"
        ] do
      assert redirected_to(get(conn, path)) == ~p"/setup"
    end

    html = get(conn, ~p"/setup") |> html_response(200)
    assert html =~ "Set up your administrator"
    assert html =~ "Send password setup link"
    refute html =~ "Create an account"
    email = unique_user_email()

    conn =
      post(conn, ~p"/setup", setup: %{email: email, password: "ignored-password", admin: false})

    assert redirected_to(conn) == ~p"/setup"
    assert_receive {:email, %Swoosh.Email{subject: "Set up your Pogo Meetups account"} = mail}
    user = Accounts.get_user_by_email(email)
    assert user.admin
    assert user.hashed_password == nil
    assert Accounts.installation_state() == :pending
    assert get(build_conn(), ~p"/setup") |> html_response(200) =~ "Check your inbox"
    assert redirected_to(get(build_conn(), ~p"/")) == ~p"/setup"
    assert redirected_to(get(build_conn(), ~p"/auth/users/log-in")) == ~p"/setup"
    # A second visitor or stale form cannot replace the selected administrator.
    second_email = unique_user_email()

    assert redirected_to(post(build_conn(), ~p"/setup", setup: %{email: second_email})) ==
             ~p"/setup"

    assert Accounts.get_user_by_email(second_email) == nil
    assert Repo.aggregate(User, :count) == 1
    [_, path] = Regex.run(~r{https?://[^/]+(/auth/users/reset-password/[^\s]+)}, mail.text_body)
    {:ok, _, html} = live(build_conn(), path)
    assert html =~ "Set your password"

    assert redirected_to(
             post(build_conn(), path,
               user: %{password: "too short", password_confirmation: "too short"}
             )
           ) == path

    assert Accounts.installation_state() == :pending

    conn =
      post(build_conn(), path,
        user: %{password: valid_user_password(), password_confirmation: valid_user_password()}
      )

    assert redirected_to(conn) == ~p"/auth/users/settings"
    assert Accounts.installation_state() == :ready
    assert get(conn, ~p"/auth/users/settings") |> html_response(200) =~ "Shared Campfire token"
    assert get(build_conn(), ~p"/") |> html_response(200) =~ "Pogo Meetups"
    assert redirected_to(get(build_conn(), ~p"/setup")) == ~p"/"
    assert Accounts.get_user_by_email_and_password(email, valid_user_password())
    assert {:error, :already_initialized} = Accounts.setup_admin(%{email: second_email}, & &1)
  end

  test "invalid email and failed SMTP leave setup available with no orphan account or token", %{
    conn: conn
  } do
    assert post(conn, ~p"/setup", setup: %{email: "invalid"}) |> html_response(200) =~
             "must have the @ sign"

    refute Repo.exists?(User)
    old = Application.fetch_env!(:ca_tools, CATools.Mailer)
    Application.put_env(:ca_tools, CATools.Mailer, adapter: FailingMailer)
    on_exit(fn -> Application.put_env(:ca_tools, CATools.Mailer, old) end)
    conn = post(build_conn(), ~p"/setup", setup: %{email: unique_user_email()})
    assert redirected_to(conn) == ~p"/setup"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Email could not be sent"
    assert Accounts.installation_state() == :empty
    refute Repo.exists?(User)
    refute Repo.exists?(UserToken)
  end

  test "an expired setup link can be replaced through email recovery", %{conn: conn} do
    email = unique_user_email()
    post(conn, ~p"/setup", setup: %{email: email})
    assert_receive {:email, %Swoosh.Email{subject: "Set up your Pogo Meetups account"} = mail}
    [_, path] = Regex.run(~r{https?://[^/]+(/auth/users/reset-password/[^\s]+)}, mail.text_body)

    Repo.update_all(UserToken,
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -2, :hour)]
    )

    {:ok, _, html} = live(build_conn(), path)
    assert html =~ "invalid or has expired"

    assert redirected_to(post(build_conn(), path, user: %{password: valid_user_password()})) ==
             ~p"/auth/users/reset-password"

    assert Accounts.installation_state() == :pending
    {:ok, lv, _} = live(build_conn(), ~p"/auth/users/reset-password")
    lv |> form("#request_reset_form", user: %{email: email}) |> render_submit()
    assert_receive {:email, %Swoosh.Email{subject: "Reset your Pogo Meetups password"} = recovery}

    [_, replacement] =
      Regex.run(~r{https?://[^/]+(/auth/users/reset-password/[^\s]+)}, recovery.text_body)

    assert redirected_to(
             post(build_conn(), replacement, user: %{password: valid_user_password()})
           ) == ~p"/auth/users/settings"

    assert Accounts.installation_state() == :ready
  end

  test "an existing installation never exposes first-run account creation", %{conn: conn} do
    user_fixture()
    assert Accounts.installation_state() == :ready
    assert redirected_to(get(conn, ~p"/setup")) == ~p"/"
    conn = post(conn, ~p"/setup", setup: %{email: unique_user_email()})
    assert redirected_to(conn) == ~p"/setup"
    assert Repo.aggregate(User, :count) == 1
    assert get(build_conn(), ~p"/") |> html_response(200) =~ "Pogo Meetups"
  end
end
