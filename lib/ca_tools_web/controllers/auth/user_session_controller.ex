defmodule CAToolsWeb.Auth.UserSessionController do
  use CAToolsWeb, :controller

  alias CATools.Accounts
  alias CAToolsWeb.Auth.UserAuth
  alias CAToolsWeb.RequestSecurity

  @doc "Creates a user session from a confirmed token, magic link, or password login."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    info_message =
      case params do
        %{"_action" => "confirmed"} -> "User confirmed successfully."
        _ -> "Welcome back!"
      end

    create_session(conn, params, info_message)
  end

  defp create_session(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/auth/users/log-in")
    end
  end

  defp create_session(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    limits = [
      {:login_password_ip, RequestSecurity.client_ip(conn)},
      {:login_password_email, RequestSecurity.normalize_email_identifier(email)}
    ]

    case RequestSecurity.check_limits(limits) do
      :ok ->
        if user = Accounts.get_user_by_email_and_password(email, password) do
          conn
          |> put_flash(:info, info)
          |> UserAuth.log_in_user(user, user_params)
        else
          # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
          conn
          |> put_flash(:error, "Invalid email or password")
          |> put_flash(:email, String.slice(email, 0, 160))
          |> redirect(to: ~p"/auth/users/log-in")
        end

      {:error, retry_after_seconds} ->
        conn
        |> put_flash(
          :error,
          "Too many login attempts. Try again in #{retry_after_seconds} seconds."
        )
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/auth/users/log-in")
    end
  end

  @doc "Updates the current user password and issues a fresh session."
  @spec update_password(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/auth/users/settings")
    |> create_session(params, "Password updated successfully!")
  end

  @doc "Logs the current user out."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
