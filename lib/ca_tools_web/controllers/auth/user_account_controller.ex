defmodule CAToolsWeb.Auth.UserAccountController do
  @moduledoc "Self-service account deletion, documented in /openapi.json."
  use CAToolsWeb, :controller
  alias CATools.Accounts
  alias CAToolsWeb.Auth.UserAuth
  import CAToolsWeb.Auth.UserAuth, only: [require_sudo_mode: 2]
  plug :require_sudo_mode

  @doc "Deletes only the authenticated account after email confirmation. OpenAPI: deleteOwnAccount."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, params) do
    email = get_in(params, ["account", "email"])

    case Accounts.delete_account(conn.assigns.current_scope, email) do
      {:ok, tokens} ->
        UserAuth.disconnect_sessions(tokens)

        conn
        |> put_flash(:info, "Your account and its data have been deleted.")
        |> UserAuth.log_out_user()

      {:error, :confirmation_required} ->
        conn
        |> put_flash(:error, "Type your current email address to confirm deletion.")
        |> redirect(to: ~p"/auth/users/settings")

      {:error, _} ->
        conn
        |> put_flash(
          :error,
          "Deletion could not finish. Your account remains available; please try again."
        )
        |> redirect(to: ~p"/auth/users/settings")
    end
  end
end
