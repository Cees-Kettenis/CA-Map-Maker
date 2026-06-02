defmodule CAToolsWeb.Auth.UserRegistrationController do
  use CAToolsWeb, :controller

  alias CATools.Accounts
  alias CATools.Accounts.User
  alias CAToolsWeb.RequestSecurity

  @doc "Renders the registration form."
  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params) do
    changeset = Accounts.change_user_email(%User{})
    render(conn, :new, changeset: changeset)
  end

  @doc "Creates a user and sends magic-link login instructions."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case params do
      %{"user" => user_params} ->
        create_user(conn, user_params)

      _ ->
        render(conn, :new, changeset: Accounts.change_user_email(%User{}))
    end
  end

  defp create_user(conn, user_params) do
    limits = [
      {:registration_ip, RequestSecurity.client_ip(conn)},
      {:registration_email, RequestSecurity.normalize_email_identifier(user_params["email"])}
    ]

    case RequestSecurity.check_limits(limits) do
      :ok ->
        case Accounts.register_user(user_params) do
          {:ok, user} ->
            {:ok, _} =
              Accounts.deliver_login_instructions(
                user,
                &url(~p"/auth/users/log-in/#{&1}")
              )

            conn
            |> put_flash(
              :info,
              "An email was sent to #{user.email}, please access it to confirm your account."
            )
            |> redirect(to: ~p"/auth/users/log-in")

          {:error, %Ecto.Changeset{} = changeset} ->
            render(conn, :new, changeset: changeset)
        end

      {:error, retry_after_seconds} ->
        conn
        |> put_flash(
          :error,
          "Too many registration attempts. Try again in #{retry_after_seconds} seconds."
        )
        |> render(:new,
          changeset: Accounts.change_user_email(%User{}, user_params, validate_unique: false)
        )
    end
  end
end
