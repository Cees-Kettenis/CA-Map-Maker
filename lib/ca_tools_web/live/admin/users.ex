defmodule CAToolsWeb.Admin.Users do
  @moduledoc "Administrator-only account creation."
  use CAToolsWeb, :live_view
  on_mount {CAToolsWeb.Auth.UserAuth, :require_admin}
  alias CATools.Accounts

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Accounts",
       users: Accounts.list_users(socket.assigns.current_scope),
       form: to_form(%{"email" => ""}, as: "user")
     )}
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1 class="atlas-display text-3xl mb-6">Accounts</h1>
      <section class="atlas-card p-6 max-w-2xl">
        <h2 class="font-semibold text-xl mb-4">Create a user</h2>
        <p class="text-sm opacity-65 mb-5">
          New users receive an email to choose their own password and share the administrator's Campfire access.
        </p>
        <.form for={@form} id="create-user-form" phx-submit="create">
          <.input field={@form[:email]} type="email" label="Email" required />
          <.button variant="primary" phx-disable-with="Creating..."><.icon
            name="hero-user-plus"
            class="size-4 shrink-0"
          /> Create user</.button>
        </.form>
      </section>
      <section class="mt-8 max-w-2xl">
        <h2 class="font-semibold text-xl mb-4">Users</h2>
        <ul class="divide-y divide-base-300">
          <li :for={user <- @users} class="py-3 flex flex-wrap justify-between gap-3">
            <span class="min-w-0 break-all">{user.email}</span><span :if={user.admin}>Administrator</span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    if Accounts.admin?(socket.assigns.current_scope) do
      case {event, params} do
        {"create", %{"user" => %{"email" => email}}} ->
          case Accounts.create_user(
                 socket.assigns.current_scope,
                 %{email: email},
                 &url(~p"/auth/users/reset-password/#{&1}")
               ) do
            {:ok, _user} ->
              {:noreply,
               assign(socket,
                 users: Accounts.list_users(socket.assigns.current_scope),
                 form: to_form(%{"email" => ""}, as: "user")
               )
               |> put_flash(
                 :info,
                 "Account created. An email to set their password has been sent."
               )}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:noreply, assign(socket, form: to_form(changeset, as: "user", action: :insert))}

            {:error, {:email_delivery, _}} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Email could not be sent. The account was not created. Please try again."
               )}

            {:error, _} ->
              {:noreply, redirect(socket, to: ~p"/")}
          end
      end
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end
end
