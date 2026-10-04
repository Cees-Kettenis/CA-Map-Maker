defmodule CAToolsWeb.SetupController do
  @moduledoc "First-run administrator setup, documented in /openapi.json."
  use CAToolsWeb, :controller
  alias CATools.{Accounts, Accounts.User}
  alias CAToolsWeb.RequestSecurity

  @doc "Shows first-run setup or redirects an initialized installation. OpenAPI: initialSetup."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Accounts.installation_state() do
      :ready ->
        redirect(conn, to: ~p"/")

      state ->
        render(conn, :show,
          state: state,
          page_title: "Set up Pogo Meetups",
          form: Phoenix.Component.to_form(Accounts.change_user_email(%User{}), as: "setup")
        )
    end
  end

  @doc "Creates the sole initial administrator and sends password setup email. OpenAPI: createInitialAdmin."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    attrs =
      case params["setup"] do
        attrs when is_map(attrs) -> attrs
        _ -> %{}
      end

    email = RequestSecurity.normalize_email_identifier(attrs["email"])

    with :ok <-
           RequestSecurity.check_limits([
             {:registration_ip, RequestSecurity.client_ip(conn)},
             {:registration_email, email}
           ]),
         {:ok, _admin} <-
           Accounts.setup_admin(%{email: email}, &url(~p"/auth/users/reset-password/#{&1}")) do
      conn
      |> put_flash(:info, "Check your email to choose your administrator password.")
      |> redirect(to: ~p"/setup")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :show,
          state: :empty,
          page_title: "Set up Pogo Meetups",
          form: Phoenix.Component.to_form(changeset, as: "setup", action: :insert)
        )

      {:error, :already_initialized} ->
        redirect(conn, to: ~p"/setup")

      {:error, {:email_delivery, _}} ->
        conn
        |> put_flash(
          :error,
          "Email could not be sent. Setup has not started. Check your email configuration and try again."
        )
        |> redirect(to: ~p"/setup")

      {:error, seconds} when is_integer(seconds) ->
        conn |> put_flash(:error, "Try again in #{seconds} seconds.") |> redirect(to: ~p"/setup")
    end
  end
end
