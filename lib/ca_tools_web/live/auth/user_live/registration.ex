defmodule CAToolsWeb.Auth.UserLive.Registration do
  use CAToolsWeb, :live_view

  alias CATools.Accounts
  alias CAToolsWeb.RequestSecurity

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="atlas-auth">
        <div class="text-center">
          <.header>Create an account</.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:password]}
            type="password"
            label="Password (optional)"
            autocomplete="new-password"
          />
          <p class="text-xs opacity-60 mb-4">
            Use at least 12 characters, or leave this blank to sign in by email.
          </p>
          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
        <.link navigate={~p"/auth/users/log-in"} class="text-sm underline mt-5 inline-block">Log in</.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t(), keyword()} | {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if not Accounts.public_signup_enabled?() do
      {:ok,
       socket
       |> put_flash(:error, "Public signups are disabled. Contact the administrator.")
       |> redirect(to: ~p"/auth/users/log-in")}
    else
      case get_in(socket.assigns, [:current_scope, Access.key(:user)]) do
        nil ->
          changeset =
            Accounts.change_user_registration(%{}, validate_unique: false, hash_password: false)

          {:ok,
           socket
           |> assign(:page_title, "Create an account")
           |> assign(:client_ip, RequestSecurity.live_client_ip(socket))
           |> assign_form(changeset), temporary_assigns: [form: nil]}

        _user ->
          {:ok, redirect(socket, to: CAToolsWeb.Auth.UserAuth.signed_in_path(socket))}
      end
    end
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    if not Accounts.public_signup_enabled?() do
      {:noreply, redirect(socket, to: ~p"/auth/users/log-in")}
    else
      case {event, params} do
        {"save", %{"user" => user_params}} ->
          limits = [
            {:registration_ip, socket.assigns.client_ip},
            {:registration_email,
             RequestSecurity.normalize_email_identifier(user_params["email"])}
          ]

          case RequestSecurity.check_limits(limits) do
            :ok ->
              case Accounts.register_user(user_params) do
                {:ok, user} ->
                  {kind, message} =
                    case Accounts.deliver_signup_instructions(
                           user,
                           &url(~p"/auth/users/log-in/#{&1}"),
                           &url(~p"/auth/users/confirm/#{&1}")
                         ) do
                      {:ok, _} ->
                        {:info,
                         "An email was sent to #{user.email}, please access it to confirm your account."}

                      {:error, _reason} ->
                        {:error,
                         "Your account was created, but we couldn't send its confirmation email. Contact the administrator."}
                    end

                  {:noreply,
                   socket
                   |> put_flash(kind, message)
                   |> push_navigate(to: ~p"/auth/users/log-in")}

                {:error, %Ecto.Changeset{} = changeset} ->
                  {:noreply, assign_form(socket, changeset)}
              end

            {:error, retry_after_seconds} ->
              {:noreply,
               socket
               |> put_flash(
                 :error,
                 "Too many registration attempts. Try again in #{retry_after_seconds} seconds."
               )
               |> assign_form(
                 Accounts.change_user_registration(user_params,
                   validate_unique: false,
                   hash_password: false
                 )
               )}
          end

        {"validate", %{"user" => user_params}} ->
          changeset =
            Accounts.change_user_registration(user_params,
              validate_unique: false,
              hash_password: false
            )

          {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
      end
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
