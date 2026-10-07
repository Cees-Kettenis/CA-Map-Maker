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
          {:noreply, Phoenix.LiveView.Socket.t()} | {:reply, map(), Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    scope = socket.assigns.current_scope

    case event do
      "copy_public_link" ->
        case socket.assigns.map &&
               Maps.update_map(scope, socket.assigns.map.id, %{visibility: :public}) do
          {:ok, map} ->
            {:reply, %{url: url(~p"/maps/#{map.public_slug}")}, assign(socket, map: map)}

          _ ->
            {:reply, %{url: nil}, put_flash(socket, :error, "Could not enable public sharing.")}
        end

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
      <div class="atlas-community-header flex flex-wrap items-center justify-between gap-4 mb-6">
        <h1 class="atlas-display text-4xl">My Communities</h1>
        <.link navigate={~p"/dashboard/maps"} class="atlas-button">
          <.icon name="hero-plus" class="size-4 shrink-0" />
          <span class="atlas-action-full-label">Create a meetup map</span>
          <span class="atlas-action-short-label">Create Map</span>
        </.link>
      </div>
      <div class="atlas-community-toolbar mb-6">
        <div :if={@communities != []} class="atlas-community-search-control">
          <span id="community-search-label" class="text-sm font-semibold">Search:</span>
          <details
            id="tracked-community-picker"
            phx-hook="CommunitySearch"
            class="atlas-community-picker"
            phx-mounted={JS.ignore_attributes("open")}
            phx-click-away={JS.remove_attribute("open", to: "#tracked-community-picker")}
            phx-window-keydown={JS.remove_attribute("open", to: "#tracked-community-picker")}
            phx-key="Escape"
          >
            <summary
              class="atlas-button"
              aria-label="Search communities and choose a community"
              phx-click={JS.remove_attribute("open", to: "#add-communities")}
            >
              <.icon name="hero-user-group" class="size-4 shrink-0" />
              <span class="min-w-0 flex-1 text-left truncate">
                {if @community,
                  do: @community.name || URI.parse(@community.source_url).path,
                  else: "Choose community"}
              </span>
              <.icon name="hero-chevron-down" class="size-4 shrink-0" />
            </summary>
            <div class="atlas-community-picker-menu space-y-3">
              <label for="tracked-community-search" class="text-sm opacity-65">Search communities</label>
              <input
                id="tracked-community-search"
                type="search"
                data-community-search
                autocomplete="off"
                placeholder="Search by name"
                aria-controls="tracked-community-list"
                class="input w-full"
              />
              <p data-community-results aria-live="polite" class="text-xs opacity-60">
                {length(@communities)} communities
              </p>
              <nav
                id="tracked-community-list"
                data-community-list
                class="atlas-community-options"
                aria-label="Tracked communities"
              >
                <button
                  :for={community <- @communities}
                  phx-click={
                    JS.push("select") |> JS.remove_attribute("open", to: "#tracked-community-picker")
                  }
                  phx-value-id={community.id}
                  data-community-option
                  data-community-name={community.name || URI.parse(community.source_url).path}
                  aria-pressed={to_string(@community && @community.id == community.id)}
                  class={[
                    "atlas-button atlas-community-option",
                    @community && @community.id == community.id && "atlas-button-primary"
                  ]}
                >
                  <img
                    :if={@group_icons[community.avatar_url]}
                    src={@group_icons[community.avatar_url]}
                    alt=""
                    class="size-6 rounded-md object-contain shrink-0"
                  />
                  <.icon
                    :if={!@group_icons[community.avatar_url]}
                    name="hero-user-group"
                    class="size-4 shrink-0"
                  />
                  <span class="truncate flex-1 text-left">{community.name ||
                    URI.parse(community.source_url).path}</span>
                  <span :if={!community.enabled} class="text-xs opacity-60 shrink-0">Paused</span>
                </button>
              </nav>
              <p data-community-empty hidden class="text-sm opacity-65">
                No communities match your search.
              </p>
            </div>
          </details>
        </div>
        <details
          id="add-communities"
          class="atlas-add-communities atlas-disclosure"
          phx-mounted={JS.ignore_attributes("open")}
          phx-click-away={JS.remove_attribute("open", to: "#add-communities")}
          phx-window-keydown={JS.remove_attribute("open", to: "#add-communities")}
          phx-key="Escape"
        >
          <summary
            class="atlas-button"
            phx-click={JS.remove_attribute("open", to: "#tracked-community-picker")}
          >
            <.icon name="hero-plus" class="size-4" /> Add communities
            <.icon name="hero-chevron-down" class="size-4 ml-auto" />
          </summary>
          <.form
            for={@links_form}
            id="community-links-form"
            phx-submit="add_groups"
            class="atlas-card p-5 space-y-3"
          >
            <.input
              field={@links_form[:links]}
              type="textarea"
              label="Group or invitation links"
              rows="2"
              placeholder="Paste one link per line"
              required
            />
            <button
              class="atlas-button atlas-button-primary w-full justify-center"
              phx-disable-with="Adding..."
            ><.icon name="hero-user-group" class="size-4 shrink-0" /> Track groups</button>
          </.form>
        </details>
      </div>
      <div class="atlas-community-layout grid lg:grid-cols-[minmax(0,1fr)_340px] gap-6">
        <div class="atlas-community-map-column">
          <section :if={@map} class="atlas-community-map-card atlas-card p-5">
            <div class="atlas-community-map-header flex justify-between items-center mb-4 gap-3">
              <h2 class="text-xl font-semibold flex items-center gap-3 min-w-0 flex-1">
                <img
                  :if={@group_icons[@community.avatar_url]}
                  src={@group_icons[@community.avatar_url]}
                  alt=""
                  class="size-12 rounded-xl object-contain shrink-0"
                />
                <span class="min-w-0 truncate" title={@community.name || "Community map"}>{@community.name ||
                  "Community map"}</span>
              </h2>
              <.link
                href={~p"/dashboard/maps/#{@map.id}/export.kml"}
                download="pogo-meetups-map.kml"
                class="atlas-button shrink-0"
              ><.icon name="hero-arrow-down-tray" class="size-4 shrink-0" /> Export KML</.link>
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
        </div>
        <aside class="atlas-community-sidebar min-w-0">
          <section id="campfire-group-settings" class="atlas-card p-5 space-y-3">
            <h2 class="text-xl font-semibold flex items-center gap-2">
              <.icon name="hero-cog-6-tooth" class="size-4 shrink-0" /> Group Settings
            </h2>
            <.form for={@community_form} id="community-form" phx-submit="save" class="space-y-3">
              <div class="atlas-group-link">
                <div class="flex items-center gap-1">
                  <label for={@community_form[:source_url].id} class="label">Group Link</label>
                  <div class="atlas-group-link-help">
                    <button
                      type="button"
                      id="group-link-help"
                      aria-label="About changing the group link"
                      aria-expanded="false"
                      aria-controls="group-link-warning"
                      aria-describedby="group-link-warning"
                      phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
                      phx-click-away={
                        JS.set_attribute({"aria-expanded", "false"}, to: "#group-link-help")
                      }
                      phx-window-keydown={
                        JS.set_attribute({"aria-expanded", "false"}, to: "#group-link-help")
                      }
                      phx-key="Escape"
                      class="atlas-info-button"
                    >
                      <.icon name="hero-information-circle" class="size-3.5" />
                    </button>
                    <p id="group-link-warning" role="tooltip" class="atlas-info-tooltip">
                      Changing the group link replaces the map and its meetups
                    </p>
                  </div>
                </div>
                <.input
                  field={@community_form[:source_url]}
                  type="url"
                  placeholder="https://campfire.onelink.me/..."
                  required
                />
              </div>
              <.input
                field={@community_form[:enabled]}
                type="checkbox"
                label="Monitor for new meetups"
              />
              <div :if={@map} class="border-t border-base-300 pt-4">
                <.update_summary map={@map} show_heading={false} show_action={false} />
              </div>
              <div class="atlas-community-actions grid gap-2 border-t border-base-300 pt-4">
                <button
                  type="submit"
                  phx-disable-with="Saving..."
                  class="atlas-button atlas-button-primary justify-center"
                >
                  <.icon name="hero-check" class="size-4 shrink-0" /> Save
                </button>
                <button
                  :if={@community && @map}
                  type="button"
                  phx-click="check"
                  phx-disable-with="Starting..."
                  class="atlas-button justify-center"
                >
                  <.icon name="hero-arrow-path" class="size-4 shrink-0" /> Update now
                </button>
                <button
                  :if={@community && @map}
                  type="button"
                  phx-click={JS.dispatch("atlas:open", to: "#delete-community-dialog")}
                  class="atlas-button atlas-button-danger justify-center"
                  aria-label="Delete community"
                >
                  <.icon name="hero-trash" class="size-4 shrink-0" /> Delete
                </button>
              </div>
            </.form>
            <p :if={@community && @community.error_message} role="alert" class="text-sm text-error">
              {@community.error_message}
            </p>
            <.link
              :if={@current_scope.user.admin}
              navigate={~p"/auth/users/settings"}
              class="text-xs underline block"
            >Manage Campfire token</.link>
          </section>
          <section :if={@community && @map} id="community-sharing" class="atlas-card p-5 space-y-3">
            <h2 class="text-xl font-semibold">Sharing</h2>
            <div>
              <div class="space-y-2">
                <.form
                  for={@invite_form}
                  id="community-invite-form"
                  phx-submit="invite"
                  class="atlas-community-invite-form"
                >
                  <div class="min-w-0">
                    <.input
                      field={@invite_form[:email]}
                      type="email"
                      label="Email to invite"
                      required
                    />
                  </div>
                  <div class="atlas-invitation-actions atlas-sharing-actions">
                    <button class="atlas-button atlas-button-primary"><.icon
                      name="hero-user-plus"
                      class="size-4 shrink-0"
                    /> Invite</button>
                    <button
                      type="button"
                      id="copy-community-public-link"
                      phx-hook="CopyLink"
                      data-prepare-event="copy_public_link"
                      class="atlas-button"
                    >
                      <.icon name="hero-globe-alt" class="size-4 shrink-0" /><span data-copy-label>Copy public link</span>
                    </button>
                    <button
                      type="button"
                      id="copy-community-link"
                      phx-hook="CopyLink"
                      data-url={url(~p"/community/maps/#{@map.id}")}
                      class="atlas-button"
                    >
                      <.icon name="hero-clipboard-document" class="size-4" /><span data-copy-label>Copy private link</span>
                    </button>
                  </div>
                </.form>
                <ul
                  :if={@community.invitations != []}
                  class="atlas-community-invitations divide-y divide-base-300"
                >
                  <li
                    :for={invitation <- @community.invitations}
                    class="flex justify-between items-center py-2 gap-3"
                  >
                    <span class="text-sm break-all min-w-0">{invitation.email}</span>
                    <button
                      phx-click="revoke"
                      phx-value-id={invitation.id}
                      class="atlas-button shrink-0"
                    ><.icon name="hero-user-minus" class="size-4 shrink-0" /> Revoke</button>
                  </li>
                </ul>
              </div>
            </div>
          </section>
        </aside>
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
