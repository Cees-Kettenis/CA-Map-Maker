defmodule CAToolsWeb.Auth.UserRecoveryController do
  @moduledoc "Single-use confirmation and password recovery, documented in /openapi.json."
  use CAToolsWeb, :controller
  alias CATools.Accounts
  alias CAToolsWeb.Auth.UserAuth
  alias CAToolsWeb.RequestSecurity

  @doc "Confirms a password account. OpenAPI: confirmAccount."
  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Account confirmed. You can now log in.")
        |> redirect(to: ~p"/auth/users/log-in")

      _ ->
        conn
        |> put_flash(:error, "Confirmation link is invalid or expired.")
        |> redirect(to: ~p"/auth/users/log-in")
    end
  end

  @doc "Changes the password with a recovery token and revokes sessions. OpenAPI: resetPassword."
  @spec reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset(conn, %{"token" => token, "user" => attrs}) do
    initial_setup? = Accounts.installation_state() == :pending

    with :ok <-
           RequestSecurity.check_limits([{:password_reset_ip, RequestSecurity.client_ip(conn)}]),
         {:ok, {user, tokens}} <- Accounts.reset_user_password(token, attrs) do
      UserAuth.disconnect_sessions(tokens)

      if initial_setup? do
        conn
        |> put_flash(
          :info,
          "Your administrator account is ready. Save the shared Campfire token below."
        )
        |> put_session(:user_return_to, ~p"/auth/users/settings")
        |> UserAuth.log_in_user(user)
      else
        conn
        |> put_flash(:info, "Password reset. Log in with your new password.")
        |> redirect(to: ~p"/auth/users/log-in")
      end
    else
      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Use matching passwords with at least 12 characters.")
        |> redirect(to: ~p"/auth/users/reset-password/#{token}")

      _ ->
        conn
        |> put_flash(:error, "Recovery link is invalid, expired, or temporarily rate limited.")
        |> redirect(to: ~p"/auth/users/reset-password")
    end
  end
end
