defmodule CAToolsWeb.Auth.UserLive.Login do
  use CAToolsWeb, :live_view

  alias CATools.Accounts
  alias CAToolsWeb.RequestSecurity

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="atlas-auth space-y-5">
        <div class="text-center">
          <.header>Log in</.header>
          <p :if={@current_scope} class="text-sm opacity-65">
            Log in again to change your account settings.
          </p>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <.link href="/dev/mailbox" class="underline">Open development mailbox</.link>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/auth/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full">
            Log in with email <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="divider">or</div>
        <.link navigate={~p"/auth/users/reset-password"} class="text-xs underline">Forgot your password?</.link>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/auth/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Log in only this time
          </.button>
        </.form>
        <.link :if={!@current_scope} navigate={~p"/auth/users/register"} class="text-sm underline">
          Create an account
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       page_title: "Log in",
       client_ip: RequestSecurity.live_client_ip(socket),
       form: form,
       trigger_submit: false
     )}
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    case {event, params} do
      {"submit_password", _params} ->
        {:noreply, assign(socket, :trigger_submit, true)}

      {"submit_magic", %{"user" => %{"email" => email}}} ->
        limits = [
          {:login_magic_ip, socket.assigns.client_ip},
          {:login_magic_email, RequestSecurity.normalize_email_identifier(email)}
        ]

        case RequestSecurity.check_limits(limits) do
          :ok ->
            case Accounts.get_user_by_email(email) do
              nil ->
                :ok

              user ->
                Accounts.deliver_login_instructions(
                  user,
                  &url(~p"/auth/users/log-in/#{&1}")
                )
            end

            info =
              "If your email is in our system, you will receive instructions for logging in shortly."

            {:noreply,
             socket
             |> put_flash(:info, info)
             |> push_navigate(to: ~p"/auth/users/log-in")}

          {:error, retry_after_seconds} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "Too many login requests. Try again in #{retry_after_seconds} seconds."
             )
             |> push_navigate(to: ~p"/auth/users/log-in")}
        end
    end
  end

  defp local_mail_adapter? do
    Application.get_env(:ca_tools, CATools.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
