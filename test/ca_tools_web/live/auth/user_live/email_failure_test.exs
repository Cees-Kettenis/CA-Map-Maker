defmodule CAToolsWeb.Auth.UserLive.EmailFailureTest do
  use CAToolsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures

  defmodule FailedMailer do
    use Swoosh.Adapter

    @doc false
    @spec deliver(Swoosh.Email.t(), keyword()) :: {:error, term()}
    def deliver(_email, _config), do: {:error, :smtp_authentication_failed}
  end

  setup do
    previous = Application.fetch_env!(:ca_tools, CATools.Mailer)
    Application.put_env(:ca_tools, CATools.Mailer, adapter: FailedMailer)
    on_exit(fn -> Application.put_env(:ca_tools, CATools.Mailer, previous) end)
    :ok
  end

  test "registration stays responsive and reports confirmation delivery failure", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/users/register")
    email = unique_user_email()

    {:ok, _login, html} =
      view
      |> form("#registration_form", user: valid_user_attributes(email: email))
      |> render_submit()
      |> follow_redirect(conn, ~p"/auth/users/log-in")

    assert html =~ "Your account was created, but we couldn&#39;t send its confirmation email"
    refute html =~ "An email was sent"
    assert CATools.Accounts.get_user_by_email(email)
  end
end
