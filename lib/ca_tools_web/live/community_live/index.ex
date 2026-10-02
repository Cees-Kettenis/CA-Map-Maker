defmodule CAToolsWeb.CommunityLive.Index do
  use CAToolsWeb, :live_view
  import CAToolsWeb.MapComponents
  alias CATools.{Communities, Maps}

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 3_000)
    community = Communities.get(socket.assigns.current_scope)

    map =
      if community && community.map_id,
        do: Maps.get_map(socket.assigns.current_scope, community.map_id)

    {:ok,
     assign(socket,
       page_title: "My Community",
       community: community,
       map: map,
       community_form: to_form(Communities.change(socket.assigns.current_scope), as: :community),
       invite_form: to_form(%{"email" => ""}, as: :invitation)
     )}
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    scope = socket.assigns.current_scope

    case event do
      "save" ->
        case Communities.save(scope, params["community"]) do
          {:ok, community} ->
            map = Maps.get_map(scope, community.map_id)

            {:noreply,
             socket
             |> assign(
               community: community,
               map: map,
               community_form: to_form(Communities.change(scope), as: :community)
             )
             |> put_flash(:info, "Community saved.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(
               socket,
               :community_form,
               to_form(%{changeset | action: :validate}, as: :community)
             )}
        end

      "check" ->
        message =
          case Communities.check_now(scope) do
            :ok ->
              "Checking for new meetups."

            {:error, :too_soon} ->
              "Your community was checked recently. The next check runs automatically."

            _ ->
              "Enable monitoring to check for meetups."
          end

        {:noreply, put_flash(socket, :info, message)}

      "invite" ->
        case Communities.invite(scope, params["invitation"]) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(
               community: Communities.get(scope),
               invite_form: to_form(%{"email" => ""}, as: :invitation)
             )
             |> put_flash(:info, "Access granted. Send them the community link.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :invite_form, to_form(changeset, as: :invitation))}

          _ ->
            {:noreply, put_flash(socket, :error, "Save a community first.")}
        end

      "revoke" ->
        Communities.revoke(scope, params["id"])
        {:noreply, assign(socket, :community, Communities.get(scope))}
    end
  end

  @impl true
  @doc false
  @spec handle_info(:refresh, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh, socket) do
    community = Communities.get(socket.assigns.current_scope)

    map =
      if community && community.map_id,
        do: Maps.get_map(socket.assigns.current_scope, community.map_id)

    Process.send_after(self(), :refresh, 3_000)
    {:noreply, assign(socket, community: community, map: map)}
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-wrap items-center justify-between gap-4 mb-8">
        <h1 class="atlas-display text-4xl">My Community</h1>
        <button :if={@community && @community.enabled} phx-click="check" class="atlas-button"><.icon
          name="hero-arrow-path"
          class="size-4"
        /> Check for meetups</button>
      </div>
      <div class="grid lg:grid-cols-[minmax(0,1fr)_340px] gap-6">
        <div class="space-y-6">
          <section :if={@map} class="atlas-card p-5">
            <div class="flex justify-between items-center mb-4 gap-4">
              <h2 class="text-xl font-semibold">{@community.name || "Community map"}</h2>
              <.link
                href={~p"/dashboard/maps/#{@map.id}/export.kml"}
                download="campfire-map.kml"
                class="atlas-button"
              >Export KML</.link>
            </div>
            <.map_canvas id="community-map" points={Maps.point_data(@map, true)} />
            <p class="text-sm opacity-65 mt-4">
              {@map.points_count} locations · {@map.sources_count} meetups discovered
            </p>
            <.link navigate={~p"/dashboard/maps/#{@map.id}"} class="text-sm underline">View import progress</.link>
          </section>
          <section :if={!@map} class="atlas-empty atlas-card p-12">
            <.icon name="hero-user-group" class="size-12 text-primary mb-4" />
            <p>Connect your Campfire group to map its meetups.</p>
          </section>
          <section :if={@community && @map} class="atlas-card p-6 space-y-4">
            <h2 class="text-xl font-semibold">Private sharing</h2>
            <p class="text-sm opacity-70">
              Invite an email, then send this link. They must sign in with that email.
            </p>
            <.form
              for={@invite_form}
              id="community-invite-form"
              phx-submit="invite"
              class="flex flex-wrap items-end gap-3"
            >
              <div class="grow">
                <.input field={@invite_form[:email]} type="email" label="Email to invite" required />
              </div>
              <button class="btn btn-primary mb-2">Invite</button>
            </.form>
            <div class="flex gap-2">
              <input
                id="community-share-url"
                type="text"
                readonly
                value={url(~p"/community/maps/#{@map.id}")}
                class="input w-full"
                aria-label="Private community link"
              />
              <button
                id="copy-community-link"
                phx-hook="CopyLink"
                data-target="#community-share-url"
                data-url={url(~p"/community/maps/#{@map.id}")}
                class="atlas-button"
              >Copy link</button>
            </div>
            <ul class="divide-y divide-base-300">
              <li
                :for={invitation <- @community.invitations}
                class="flex justify-between items-center py-3 gap-3"
              >
                <span class="text-sm break-all">{invitation.email}</span>
                <button phx-click="revoke" phx-value-id={invitation.id} class="text-sm underline">Revoke</button>
              </li>
            </ul>
          </section>
        </div>
        <section class="atlas-card p-6 self-start space-y-4">
          <h2 class="text-xl font-semibold">Campfire group</h2>
          <.form for={@community_form} id="community-form" phx-submit="save">
            <.input
              field={@community_form[:source_url]}
              type="url"
              label="Group or invitation link"
              placeholder="https://campfire.onelink.me/..."
              required
            />
            <.input field={@community_form[:enabled]} type="checkbox" label="Monitor for new meetups" />
            <button class="btn btn-primary mt-4" phx-disable-with="Saving...">Save community</button>
          </.form>
          <p class="text-sm opacity-65">
            New meetups are checked every 10 minutes using your saved Campfire token. Your map stays private.
          </p>
          <p class="text-xs opacity-65">
            Changing groups replaces the map and clears its invitations.
          </p>
          <p :if={@community && @community.last_checked_at} class="text-sm opacity-65">
            Last checked {Calendar.strftime(@community.last_checked_at, "%d %b · %H:%M UTC")}
          </p>
          <p :if={@community && @community.error_message} role="alert" class="text-sm text-error">
            {@community.error_message}
          </p>
          <.link navigate={~p"/auth/users/settings"} class="text-sm underline">Manage Campfire token</.link>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
