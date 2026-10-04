defmodule CAToolsWeb.CommunityLive.Index do
  use CAToolsWeb, :live_view
  import CAToolsWeb.MapComponents
  alias CATools.{Communities, Maps}

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: Maps.subscribe(socket.assigns.current_scope.user.id)

    community = Communities.get(socket.assigns.current_scope)

    map =
      if community && community.map_id,
        do: Maps.get_map(socket.assigns.current_scope, community.map_id)

    {:ok,
     assign(socket,
       page_title: "My Communities",
       communities: Communities.list(socket.assigns.current_scope),
       links_form: to_form(%{"links" => ""}, as: :groups),
       community: community,
       show_past?: false,
       view_time: DateTime.utc_now(),
       expiry_timer: if(connected?(socket) && map, do: Maps.schedule_expiry(map.points)),
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
      "toggle_past" ->
        {:noreply, assign(socket, show_past?: !socket.assigns.show_past?)}

      "delete_community" ->
        case Communities.delete(scope, params["id"]) do
          {:ok, _} ->
            {:noreply, socket |> refresh_selection() |> put_flash(:info, "Community deleted.")}

          _ ->
            {:noreply, refresh_selection(socket)}
        end

      "retry_images" ->
        case CATools.Maps.ImageCache.retry_failed(
               scope,
               socket.assigns.map && socket.assigns.map.id
             ) do
          {:ok, count} ->
            {:noreply,
             put_flash(socket, :info, "#{count} failed image downloads queued for retry.")}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not retry image downloads.")}
        end

      "add_groups" ->
        case Communities.add_links(scope, params["groups"]["links"]) do
          {:ok, added} ->
            community =
              (socket.assigns.community &&
                 Communities.get(scope, socket.assigns.community.id)) ||
                List.first(added)

            {:noreply,
             socket
             |> assign(
               communities: Communities.list(scope),
               community: community,
               map: Maps.get_map(scope, community.map_id),
               community_form:
                 to_form(Communities.change(scope, %{}, community.id), as: :community),
               links_form: to_form(%{"links" => ""}, as: :groups)
             )
             |> put_flash(:info, "Groups added. Discovery runs in the background.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               Enum.map_join(changeset.errors, " ", fn {_, {message, _}} -> message end)
             )}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end

      "select" ->
        case Communities.get(scope, params["id"]) do
          nil ->
            {:noreply, socket}

          community ->
            map = Maps.get_map(scope, community.map_id)

            {:noreply,
             assign(socket,
               community: community,
               map: map,
               view_time: DateTime.utc_now(),
               expiry_timer: Maps.schedule_expiry(map.points, socket.assigns.expiry_timer),
               community_form:
                 to_form(Communities.change(scope, %{}, community.id), as: :community),
               invite_form: to_form(%{"email" => ""}, as: :invitation)
             )}
        end

      "save" ->
        case Communities.save(
               scope,
               params["community"],
               socket.assigns.community && socket.assigns.community.id
             ) do
          {:ok, community} ->
            map = Maps.get_map(scope, community.map_id)

            {:noreply,
             socket
             |> assign(
               community: community,
               communities: Communities.list(scope),
               map: map,
               community_form:
                 to_form(Communities.change(scope, %{}, community.id), as: :community)
             )
             |> put_flash(:info, "Community saved.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(
               socket,
               :community_form,
               to_form(%{changeset | action: :validate}, as: :community)
             )}

          {:error, _} ->
            {:noreply,
             refresh_selection(socket) |> put_flash(:error, "This community was removed.")}
        end

      "check" ->
        message =
          case Communities.check_now(
                 scope,
                 socket.assigns.community && socket.assigns.community.id
               ) do
            :ok ->
              "Checking for new meetups."

            _ ->
              "Enable monitoring to check for meetups."
          end

        {:noreply, put_flash(socket, :info, message)}

      "invite" ->
        case Communities.invite(
               scope,
               params["invitation"],
               socket.assigns.community && socket.assigns.community.id
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(
               community:
                 Communities.get(scope, socket.assigns.community && socket.assigns.community.id),
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

        {:noreply,
         assign(
           socket,
           :community,
           Communities.get(scope, socket.assigns.community && socket.assigns.community.id)
         )}
    end
  end

  @impl true
  @doc false
  @spec handle_info(:refresh, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh, socket) do
    socket = refresh_selection(socket)

    {:noreply,
     assign(socket,
       view_time: DateTime.utc_now(),
       expiry_timer:
         Maps.schedule_expiry(
           if(socket.assigns.map, do: socket.assigns.map.points, else: []),
           socket.assigns.expiry_timer
         )
     )}
  end

  # Notifications and deletion both need to replace a stale selection without resetting edited forms.
  defp refresh_selection(socket) do
    scope = socket.assigns.current_scope
    communities = Communities.list(scope)
    old_id = socket.assigns.community && socket.assigns.community.id
    community = Enum.find(communities, &(&1.id == old_id)) || List.first(communities)
    map = if community, do: Maps.get_map(scope, community.map_id)
    socket = assign(socket, community: community, map: map, communities: communities)

    if old_id != (community && community.id) do
      assign(socket,
        community_form:
          to_form(Communities.change(scope, %{}, community && community.id), as: :community),
        invite_form: to_form(%{"email" => ""}, as: :invitation),
        show_past?: false
      )
    else
      socket
    end
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :group_icons,
        CATools.Maps.ImageCache.local_urls(Enum.map(assigns.communities, & &1.avatar_url))
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-wrap items-center justify-between gap-4 mb-8">
        <h1 class="atlas-display text-4xl">My Communities</h1>
        <div class="flex flex-wrap gap-2">
          <button
            :if={@community && @map}
            phx-click={JS.dispatch("atlas:open", to: "#delete-community-dialog")}
            class="atlas-button atlas-button-danger"
          ><.icon name="hero-trash" class="size-4" /> Delete community</button>
          <button :if={@community && @community.enabled} phx-click="check" class="atlas-button"><.icon
            name="hero-arrow-path"
            class="size-4"
          /> Check for meetups</button>
        </div>
      </div>
      <section class="atlas-card p-6 mb-6">
        <.form for={@links_form} id="community-links-form" phx-submit="add_groups" class="space-y-3">
          <.input
            field={@links_form[:links]}
            type="textarea"
            label="Add communities"
            rows="3"
            placeholder="Paste one group or invitation link per line"
            required
          />
          <div class="flex flex-wrap items-center gap-3">
            <button class="btn btn-primary" phx-disable-with="Adding...">Track groups</button>
            <.link navigate={~p"/dashboard/maps"} class="atlas-button">Create a meetup map
            <.icon name="hero-arrow-right" class="size-4" /></.link>
          </div>
        </.form>
      </section>
      <nav :if={@communities != []} class="flex flex-wrap gap-3 mb-6" aria-label="Tracked communities">
        <button
          :for={community <- @communities}
          phx-click="select"
          phx-value-id={community.id}
          aria-pressed={if @community && @community.id == community.id, do: "true", else: "false"}
          class={
            if @community && @community.id == community.id,
              do: "atlas-button atlas-button-primary atlas-community-tab",
              else: "atlas-button atlas-community-tab"
          }
        >
          <img
            :if={@group_icons[community.avatar_url]}
            src={@group_icons[community.avatar_url]}
            alt=""
            class="size-6 rounded-md object-contain shrink-0"
          />
          <.icon :if={!@group_icons[community.avatar_url]} name="hero-user-group" class="size-4" />
          <span class="truncate">{community.name || URI.parse(community.source_url).path}</span>
          <span :if={!community.enabled} class="text-xs opacity-60">Paused</span>
        </button>
      </nav>
      <div class="grid lg:grid-cols-[minmax(0,1fr)_340px] gap-6">
        <div class="space-y-6">
          <section :if={@map} class="atlas-card p-5">
            <div class="flex justify-between items-center mb-4 gap-4">
              <h2 class="text-xl font-semibold flex items-center gap-3">
                <img
                  :if={@group_icons[@community.avatar_url]}
                  src={@group_icons[@community.avatar_url]}
                  alt=""
                  class="size-12 rounded-xl object-contain shrink-0"
                />
                {@community.name || "Community map"}
              </h2>
              <.link
                href={~p"/dashboard/maps/#{@map.id}/export.kml"}
                download="pogo-meetups-map.kml"
                class="atlas-button"
              >Export KML</.link>
            </div>
            <.map_canvas id="community-map" points={Maps.point_data(@map, true)} now={@view_time} />
            <p class="text-sm opacity-65 mt-4">
              {length(Maps.active_points(Maps.point_data(@map)))} locations · {@map.sources_count} meetups discovered
            </p>
            <.image_status points={@map.points} retry_event="retry_images" />
            <.link navigate={~p"/dashboard/maps/#{@map.id}"} class="text-sm underline">View map updates</.link>
          </section>
          <section :if={!@map} class="atlas-empty atlas-card p-12">
            <.icon name="hero-user-group" class="size-12 text-primary mb-4" />
            <p>Connect your Campfire group to map its meetups.</p>
          </section>
          <section :if={@community && @map} class="atlas-card p-6 space-y-4">
            <h2 class="text-xl font-semibold">Public sharing</h2>
            <p class="text-sm opacity-70">
              Share a read-only map with anyone, without requiring them to sign in.
            </p>
            <.link navigate={~p"/dashboard/maps/#{@map.id}" <> "#map-sharing"} class="atlas-button">Manage public link</.link>
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
            Communities and upcoming meetups update once a day. Use Update now whenever you need fresh details.
          </p>
          <p class="text-xs opacity-65">
            Changing groups replaces the map and clears its invitations.
          </p>
          <.update_summary :if={@map} map={@map} event="check" />
          <p :if={@community && @community.error_message} role="alert" class="text-sm text-error">
            {@community.error_message}
          </p>
          <.link navigate={~p"/auth/users/settings"} class="text-sm underline">Manage Campfire token</.link>
        </section>
      </div>
      <.meetup_section
        :if={@map}
        id="community-meetups"
        points={Maps.point_data(@map, true)}
        show_past={@show_past?}
        now={@view_time}
      />
      <.delete_confirmation
        :if={@map && @community}
        id="delete-community-dialog"
        name={@community.name || "Campfire group"}
        event="delete_community"
        target_id={@community.id}
        community
      />
    </Layouts.app>
    """
  end
end
