defmodule CAToolsWeb.MapLive.Index do
  use CAToolsWeb, :live_view

  alias CATools.Maps

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Map Dashboard")
     |> assign(:map_form, to_form(Maps.change_map(scope), as: "map"))
     |> assign(:maps, Maps.list_maps(scope))}
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="space-y-8">
        <.header>
          Map Dashboard
          <:subtitle>
            Create a map from Campfire links and track which links are still pending import.
          </:subtitle>
        </.header>

        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body space-y-4">
            <.header>
              New Map
              <:subtitle>
                Paste one Campfire link per line. Only `cmpf.re` and `campfire.nianticlabs.com` links are accepted.
              </:subtitle>
            </.header>

            <.form for={@map_form} id="map_form" phx-change="validate" phx-submit="save">
              <div class="grid gap-4 sm:grid-cols-2">
                <.input field={@map_form[:name]} type="text" label="Map name" required />
                <.input
                  field={@map_form[:visibility]}
                  type="select"
                  label="Visibility"
                  options={[{"Private", :private}, {"Public", :public}]}
                  required
                />
              </div>

              <.input
                field={@map_form[:description]}
                type="textarea"
                label="Description"
                rows="3"
              />

              <.input
                field={@map_form[:source_urls_input]}
                type="textarea"
                label="Campfire links"
                rows="8"
                required
              />

              <.button variant="primary" phx-disable-with="Creating...">Create Map</.button>
            </.form>
          </div>
        </section>

        <section class="space-y-4">
          <.header>
            Your Maps
            <:subtitle>
              Only maps you own appear here.
            </:subtitle>
          </.header>

          <div
            :if={@maps == []}
            class="rounded-xl border border-dashed border-base-300 p-8 text-center"
          >
            <p class="font-medium">No maps yet.</p>
            <p class="text-sm text-base-content/70">
              Create your first map to start queuing Campfire imports.
            </p>
          </div>

          <div :for={map <- @maps} class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body gap-4">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div class="space-y-1">
                  <h2 class="text-lg font-semibold">{map.name}</h2>
                  <p :if={map.description} class="text-sm text-base-content/80">
                    {map.description}
                  </p>
                </div>

                <div class="badge badge-outline">{map.visibility}</div>
              </div>

              <div class="grid gap-3 text-sm sm:grid-cols-4">
                <div class="rounded-lg bg-base-200 p-3">
                  <p class="text-base-content/70">Sources</p>
                  <p class="text-lg font-semibold">{map.sources_count}</p>
                </div>
                <div class="rounded-lg bg-base-200 p-3">
                  <p class="text-base-content/70">Pending</p>
                  <p class="text-lg font-semibold">
                    {Enum.count(map.sources, &(&1.status == :pending))}
                  </p>
                </div>
                <div class="rounded-lg bg-base-200 p-3">
                  <p class="text-base-content/70">Fetched</p>
                  <p class="text-lg font-semibold">
                    {Enum.count(map.sources, &(&1.status == :fetched))}
                  </p>
                </div>
                <div class="rounded-lg bg-base-200 p-3">
                  <p class="text-base-content/70">Failed</p>
                  <p class="text-lg font-semibold">
                    {Enum.count(map.sources, &(&1.status == :failed))}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    case {event, params} do
      {"validate", %{"map" => map_params}} ->
        form =
          socket.assigns.current_scope
          |> Maps.change_map(map_params)
          |> Map.put(:action, :validate)
          |> to_form(as: "map")

        {:noreply, assign(socket, :map_form, form)}

      {"save", %{"map" => map_params}} ->
        case Maps.create_map(socket.assigns.current_scope, map_params) do
          {:ok, _map} ->
            {:noreply,
             socket
             |> put_flash(:info, "Map created. Campfire links have been queued for import.")
             |> assign(:maps, Maps.list_maps(socket.assigns.current_scope))
             |> assign(
               :map_form,
               to_form(Maps.change_map(socket.assigns.current_scope), as: "map")
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket, :map_form, to_form(Map.put(changeset, :action, :insert), as: "map"))}

          {:error, :unauthorized} ->
            {:noreply, redirect(socket, to: ~p"/auth/users/log-in")}
        end
    end
  end
end
