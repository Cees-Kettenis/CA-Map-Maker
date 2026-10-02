defmodule CAToolsWeb.MapLive.Index do
  use CAToolsWeb, :live_view
  alias CATools.{Accounts, Communities, Maps, MeetupMaps}
  alias CAToolsWeb.RequestSecurity

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: Maps.subscribe(socket.assigns.current_scope.user.id)
    scope = socket.assigns.current_scope

    communities = Communities.list(scope)

    {:ok,
     assign(socket,
       page_title: "My Maps",
       maps: Maps.list_maps(scope),
       map_filter: "all",
       communities: communities,
       map_mode: if(communities == [], do: "links", else: "communities"),
       meetup_form:
         to_form(
           MeetupMaps.change(%{
             utc_offset_minutes: 0,
             community_ids: Enum.map(communities, & &1.id)
           }),
           as: "meetup"
         ),
       token_saved?: Accounts.user_has_campfire_token?(scope.user),
       client_ip: RequestSecurity.live_client_ip(socket),
       map_form: to_form(Maps.change_map(scope), as: "map")
     )}
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :visible_maps,
        Enum.filter(assigns.maps, fn map ->
          case assigns.map_filter do
            "created" -> is_nil(map.community)
            "community" -> not is_nil(map.community)
            _ -> true
          end
        end)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="atlas-dashboard-hero mb-7">
        <div class="atlas-hero-content">
          <h1 class="atlas-display text-4xl sm:text-5xl mb-7">My Maps</h1>
          <div class="atlas-metrics">
            <div class="atlas-metric">
              <span class="atlas-metric-icon"><.icon name="hero-map" class="size-5" /></span>
              <div>
                <p class="text-xs opacity-65">Maps</p><p class="text-2xl font-semibold">
                  {length(@maps)}
                </p>
              </div>
            </div>
            <div class="atlas-metric">
              <span class="atlas-metric-icon" data-tone="coral"><.icon
                name="hero-map-pin"
                class="size-5"
              /></span>
              <div>
                <p class="text-xs opacity-65">Locations</p><p class="text-2xl font-semibold">
                  {Enum.sum(Enum.map(@maps, & &1.points_count))}
                </p>
              </div>
            </div>
            <div class="atlas-metric">
              <span class="atlas-metric-icon" data-tone="violet"><.icon
                name="hero-globe-alt"
                class="size-5"
              /></span>
              <div>
                <p class="text-xs opacity-65">Public maps</p><p class="text-2xl font-semibold">
                  {Enum.count(@maps, &(&1.visibility == :public))}
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>
      <section
        :if={!@token_saved?}
        class="atlas-card atlas-token-notice p-5 mb-7 flex flex-wrap gap-4 items-center justify-between"
      >
        <div class="flex items-center gap-3">
          <.icon name="hero-key" class="size-5" />
          <p class="text-sm">Save a Campfire token to import meetups.</p>
        </div>
        <.link navigate={~p"/auth/users/settings"} class="atlas-button">Set up token
        <.icon name="hero-arrow-up-right" class="size-4" /></.link>
      </section>
      <div class="grid lg:grid-cols-[360px_1fr] gap-8 items-start">
        <section class="atlas-card atlas-create-card p-6">
          <h2 class="text-xl font-semibold mb-6 flex items-center gap-3">
            <span class="atlas-section-icon"><.icon name="hero-plus" class="size-5" /></span>
            Make a new map
          </h2>
          <div class="grid grid-cols-2 gap-2 mb-5" aria-label="Map source">
            <button
              phx-click="mode"
              phx-value-mode="communities"
              aria-pressed={@map_mode == "communities"}
              class={
                if @map_mode == "communities",
                  do: "atlas-button atlas-button-primary w-full justify-center",
                  else: "atlas-button w-full justify-center"
              }
            >Communities</button>
            <button
              phx-click="mode"
              phx-value-mode="links"
              aria-pressed={@map_mode == "links"}
              class={
                if @map_mode == "links",
                  do: "atlas-button atlas-button-primary w-full justify-center",
                  else: "atlas-button w-full justify-center"
              }
            >Paste links</button>
          </div>
          <.form
            :if={@map_mode == "communities"}
            for={@meetup_form}
            id="meetup-map-form"
            phx-hook="MeetupDate"
            phx-submit="create_meetup"
            class="space-y-4"
          >
            <.input
              field={@meetup_form[:name]}
              label="Map name"
              placeholder="Saturday meetups"
              required
            />
            <.input field={@meetup_form[:meetup_date]} type="date" label="Meetup date" required />
            <input
              id="meetup-date-offset"
              type="hidden"
              name="meetup[utc_offset_minutes]"
              value={@meetup_form[:utc_offset_minutes].value || 0}
            />
            <fieldset class="space-y-2">
              <legend class="text-sm opacity-65 mb-2">Communities</legend>
              <label
                :for={community <- @communities}
                class="flex items-center gap-3 rounded-xl border border-base-300 p-3 cursor-pointer"
              >
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name="meetup[community_ids][]"
                  value={community.id}
                  checked={
                    to_string(community.id) in Enum.map(
                      @meetup_form[:community_ids].value || [],
                      &to_string/1
                    )
                  }
                />
                <span class="text-sm truncate">{community.name || URI.parse(community.source_url).path}</span>
              </label>
              <p :for={{message, _} <- @meetup_form[:community_ids].errors} class="text-sm text-error">
                {message}
              </p>
            </fieldset>
            <.link :if={@communities == []} navigate={~p"/dashboard/community"} class="atlas-button">Add communities first</.link>
            <p class="text-xs opacity-65">
              Creates a private map that stays linked to these groups. Meetup details update as imports finish.
            </p>
            <.button
              :if={@communities != []}
              variant="primary"
              class="atlas-button atlas-button-primary w-full justify-center"
              phx-disable-with="Creating..."
            >Create meetup map <.icon name="hero-arrow-right" class="size-4" /></.button>
          </.form>
          <.form
            :if={@map_mode == "links"}
            for={@map_form}
            id="map_form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.input
              field={@map_form[:name]}
              type="text"
              label="Map name"
              placeholder="Sunday raids in the city"
              required
            />
            <.input
              field={@map_form[:description]}
              type="textarea"
              label="Description"
              rows="2"
              placeholder="Optional description"
            />
            <.input
              field={@map_form[:visibility]}
              type="select"
              label="Visibility"
              options={[{"Private · only you", :private}, {"Public · anyone with the link", :public}]}
              required
            />
            <.input
              field={@map_form[:source_urls_input]}
              type="textarea"
              label="Campfire links (one per line)"
              rows="6"
              placeholder="https://cmpf.re/..."
              required
            />
            <p class="text-[11px] opacity-55">
              Up to 10,000 links. Meetups fetch in the background and update once a day.
            </p>
            <.button
              variant="primary"
              class="atlas-button atlas-button-primary w-full justify-center"
              phx-disable-with="Creating..."
            >Create Map <.icon name="hero-arrow-right" class="size-4" /></.button>
          </.form>
        </section>
        <section class="min-w-0">
          <nav class="flex flex-wrap gap-2 mb-5" aria-label="Filter maps">
            <button
              :for={
                {label, filter} <- [
                  {"All Maps", "all"},
                  {"Created Maps", "created"},
                  {"Community Maps", "community"}
                ]
              }
              phx-click="filter_maps"
              phx-value-filter={filter}
              aria-pressed={to_string(@map_filter == filter)}
              class={["atlas-button", @map_filter == filter && "atlas-button-primary"]}
            >{label}</button>
          </nav>
          <div :if={@visible_maps == []} class="atlas-empty">
            <.icon name="hero-map" class="size-10 opacity-40 mb-4" />
            <p class="text-sm opacity-65">
              {if @map_filter == "all", do: "No maps yet.", else: "No maps in this category yet."}
            </p>
          </div>
          <div id="map-cards" class="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-4 gap-3">
            <article :for={map <- @visible_maps} class="atlas-card atlas-map-card">
              <.link
                navigate={~p"/dashboard/maps/#{map.id}"}
                class={[
                  "block atlas-map-cover aspect-square relative",
                  if(map.community_icon_url, do: "atlas-community-cover", else: "atlas-map-art")
                ]}
              >
                <img
                  :if={map.community_icon_url}
                  src={map.community_icon_url}
                  alt={map.name}
                  loading="lazy"
                  class="h-full w-full object-contain p-2"
                />
              </.link>
              <div class="p-3">
                <.link
                  navigate={~p"/dashboard/maps/#{map.id}"}
                  class="font-semibold text-xs leading-snug line-clamp-2 hover:underline"
                >{map.name}</.link>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec handle_info(:refresh, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh, socket) do
    {:noreply,
     assign(socket,
       maps: Maps.list_maps(socket.assigns.current_scope),
       communities: Communities.list(socket.assigns.current_scope)
     )}
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    case event do
      "filter_maps" ->
        filter =
          if params["filter"] in ["all", "created", "community"],
            do: params["filter"],
            else: "all"

        {:noreply, assign(socket, map_filter: filter)}

      "mode" ->
        {:noreply,
         assign(
           socket,
           :map_mode,
           if(params["mode"] == "communities", do: "communities", else: "links")
         )}

      "create_meetup" ->
        with :ok <- RequestSecurity.check_limits([{:map_create_ip, socket.assigns.client_ip}]),
             {:ok, map} <- MeetupMaps.create(socket.assigns.current_scope, params["meetup"]) do
          {:noreply, push_navigate(socket, to: ~p"/dashboard/maps/#{map.id}")}
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, meetup_form: to_form(changeset, as: "meetup"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not create this map. Try again shortly.")}
        end

      "validate" ->
        params = params["map"]

        form =
          Maps.change_map(socket.assigns.current_scope, params)
          |> Map.put(:action, :validate)
          |> to_form(as: "map")

        {:noreply, assign(socket, map_form: form)}

      "save" ->
        params = params["map"]

        with :ok <- RequestSecurity.check_limits([{:map_create_ip, socket.assigns.client_ip}]),
             {:ok, _map} <- Maps.create_map(socket.assigns.current_scope, params) do
          {:noreply,
           socket
           |> put_flash(:info, "Map created. Campfire links have been queued for import.")
           |> assign(
             maps: Maps.list_maps(socket.assigns.current_scope),
             map_form: to_form(Maps.change_map(socket.assigns.current_scope), as: "map")
           )}
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket, map_form: to_form(Map.put(changeset, :action, :insert), as: "map"))}

          {:error, :unauthorized} ->
            {:noreply, redirect(socket, to: ~p"/auth/users/log-in")}

          {:error, {:rate_limited, seconds}} ->
            {:noreply, put_flash(socket, :error, "Try again in #{seconds} seconds.")}

          {:error, seconds} when is_integer(seconds) ->
            {:noreply, put_flash(socket, :error, "Try again in #{seconds} seconds.")}
        end
    end
  end
end
