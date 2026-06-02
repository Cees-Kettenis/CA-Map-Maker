defmodule CAToolsWeb.Auth.UserLive.Settings do
  use CAToolsWeb, :live_view

  on_mount {CAToolsWeb.Auth.UserAuth, :require_sudo_mode}

  alias CATools.Accounts

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/auth/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(params, _session, socket) do
    case params do
      %{"token" => token} ->
        mounted_socket =
          case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
            {:ok, _user} ->
              put_flash(socket, :info, "Email changed successfully.")

            {:error, _} ->
              put_flash(socket, :error, "Email change link is invalid or it has expired.")
          end

        {:ok, push_navigate(mounted_socket, to: ~p"/auth/users/settings")}

      _ ->
        user = socket.assigns.current_scope.user
        email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
        password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

        mounted_socket =
          socket
          |> assign(:current_email, user.email)
          |> assign(:email_form, to_form(email_changeset))
          |> assign(:password_form, to_form(password_changeset))
          |> assign(:trigger_submit, false)

        {:ok, mounted_socket}
    end
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    case {event, params} do
      {"validate_email", %{"user" => user_params}} ->
        email_form =
          socket.assigns.current_scope.user
          |> Accounts.change_user_email(user_params, validate_unique: false)
          |> Map.put(:action, :validate)
          |> to_form()

        {:noreply, assign(socket, email_form: email_form)}

      {"update_email", %{"user" => user_params}} ->
        user = socket.assigns.current_scope.user
        true = Accounts.sudo_mode?(user)

        case Accounts.change_user_email(user, user_params) do
          %{valid?: true} = changeset ->
            Accounts.deliver_user_update_email_instructions(
              Ecto.Changeset.apply_action!(changeset, :insert),
              user.email,
              &url(~p"/auth/users/settings/confirm-email/#{&1}")
            )

            info = "A link to confirm your email change has been sent to the new address."
            {:noreply, socket |> put_flash(:info, info)}

          changeset ->
            {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
        end

      {"validate_password", %{"user" => user_params}} ->
        password_form =
          socket.assigns.current_scope.user
          |> Accounts.change_user_password(user_params, hash_password: false)
          |> Map.put(:action, :validate)
          |> to_form()

        {:noreply, assign(socket, password_form: password_form)}

      {"update_password", %{"user" => user_params}} ->
        user = socket.assigns.current_scope.user
        true = Accounts.sudo_mode?(user)

        case Accounts.change_user_password(user, user_params) do
          %{valid?: true} = changeset ->
            {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

          changeset ->
            {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
        end
    end
  end
end
