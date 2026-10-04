defmodule CAToolsWeb.Auth.UserLive.Recovery do
  use CAToolsWeb, :live_view
  alias CATools.Accounts
  alias CAToolsWeb.RequestSecurity

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(params, _session, socket) do
    token = params["token"]
    user = if token, do: Accounts.get_user_by_password_reset_token(token)
    valid? = is_nil(token) or not is_nil(user)
    setup? = user != nil and is_nil(user.hashed_password)

    {:ok,
     assign(socket,
       token: token,
       valid?: valid?,
       setup?: setup?,
       page_title: if(setup?, do: "Set your password", else: "Reset password"),
       client_ip: RequestSecurity.live_client_ip(socket),
       form: to_form(%{}, as: "user")
     )}
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="atlas-auth space-y-5">
        <h1 class="atlas-display text-2xl">
          {@page_title}
        </h1>
        <%= cond do %>
          <% !@valid? -> %>
            <p class="text-sm opacity-65">This recovery link is invalid or has expired.</p><.link
              navigate={~p"/auth/users/reset-password"}
              class="btn btn-primary"
            >Request a new link</.link>
          <% @token != nil -> %>
            <.form
              for={@form}
              id="reset_password_form"
              action={~p"/auth/users/reset-password/#{@token}"}
              method="post"
            >
              <.input
                field={@form[:password]}
                type="password"
                label="New password"
                autocomplete="new-password"
                required
              />
              <.input
                field={@form[:password_confirmation]}
                type="password"
                label="Confirm password"
                autocomplete="new-password"
                required
              />
              <p class="text-xs opacity-60 mb-4">
                At least 12 characters. Existing sessions will be signed out.
              </p><.button variant="primary" class="w-full">{if @setup?,
                do: "Set password",
                else: "Reset password"}</.button>
            </.form>
          <% true -> %>
            <.form for={@form} id="request_reset_form" phx-submit="request_reset">
              <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
              <.button variant="primary" class="w-full">Send recovery link</.button>
            </.form>
        <% end %>
        <.link navigate={~p"/auth/users/log-in"} class="text-xs underline">Back to log in</.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("request_reset", %{"user" => %{"email" => email}}, socket) do
    limits = [
      {:password_reset_ip, socket.assigns.client_ip},
      {:password_reset_email, RequestSecurity.normalize_email_identifier(email)}
    ]

    case RequestSecurity.check_limits(limits) do
      :ok ->
        case Accounts.get_user_by_email(email) do
          %{confirmed_at: confirmed} = user when not is_nil(confirmed) ->
            Accounts.deliver_password_reset_instructions(
              user,
              &url(~p"/auth/users/reset-password/#{&1}")
            )

          _ ->
            :ok
        end

        {:noreply,
         put_flash(
           socket,
           :info,
           "If your email is in our system, a recovery link is on its way."
         )}

      {:error, seconds} ->
        {:noreply, put_flash(socket, :error, "Try again in #{seconds} seconds.")}
    end
  end
end
