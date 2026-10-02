defmodule CAToolsWeb.MapLive.Index do
  use CAToolsWeb, :live_view
  alias CATools.{Accounts, Maps}
  alias CAToolsWeb.RequestSecurity

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_maps, 3_000)
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: "My Maps",
       maps: Maps.list_maps(scope),
       token_saved?: Accounts.user_has_campfire_token?(scope.user),
       client_ip: RequestSecurity.live_client_ip(socket),
       map_form: to_form(Maps.change_map(scope), as: "map")
     )}
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
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
          <.form
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
              Up to 10,000 links. Imports run in batches of 50 every 10 minutes.
            </p>
            <.button variant="primary" class="w-full" phx-disable-with="Creating...">Create Map
            <.icon name="hero-arrow-right" class="size-4" /></.button>
          </.form>
        </section>
        <section>
          <div :if={@maps == []} class="atlas-empty">
            <.icon name="hero-map" class="size-10 opacity-40 mb-4" />
            <p class="text-sm opacity-65">No maps yet.</p>
          </div>
          <div class="grid sm:grid-cols-2 gap-5">
            <article :for={map <- @maps} class="atlas-card atlas-map-card">
              <.link
                navigate={~p"/dashboard/maps/#{map.id}"}
                class="block atlas-map-art atlas-map-cover h-44 relative"
              >
                <span class="atlas-status absolute top-4 left-4">{map.visibility}</span>
                <span class="absolute bottom-3 right-3 atlas-button !p-2" aria-label="Open map"><.icon
                  name="hero-arrow-up-right"
                  class="size-4"
                /></span>
              </.link>
              <div class="p-5">
                <.link
                  navigate={~p"/dashboard/maps/#{map.id}"}
                  class="font-semibold text-lg hover:underline"
                >{map.name}</.link>
                <p :if={map.description not in [nil, ""]} class="text-xs opacity-65 mt-2 line-clamp-2">
                  {map.description}
                </p>
                <div class="flex justify-between text-xs mt-5 mb-3">
                  <span>{map.points_count} locations</span><span class="opacity-60">{map.sources_count} Sources</span>
                </div>
                <progress
                  class="progress progress-primary h-1"
                  value={Enum.count(map.sources, &(&1.status in [:fetched, :failed, :skipped]))}
                  max={max(map.sources_count, 1)}
                  aria-label="Import progress"
                ></progress>
                <div class="flex gap-3 mt-3 text-[11px] opacity-70">
                  <span>{Enum.count(map.sources, &(&1.status == :pending))} Pending</span>
                  <span>{Enum.count(map.sources, &(&1.status == :fetched))} Fetched</span>
                  <span>{Enum.count(map.sources, &(&1.status == :failed))} Failed</span>
                </div>
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
  @spec handle_info(:refresh_maps, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh_maps, socket) do
    Process.send_after(self(), :refresh_maps, 3_000)
    {:noreply, assign(socket, maps: Maps.list_maps(socket.assigns.current_scope))}
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, %{"map" => params}, socket) do
    case event do
      "validate" ->
        form =
          Maps.change_map(socket.assigns.current_scope, params)
          |> Map.put(:action, :validate)
          |> to_form(as: "map")

        {:noreply, assign(socket, map_form: form)}

      "save" ->
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
