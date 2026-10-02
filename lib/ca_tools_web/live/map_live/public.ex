defmodule CAToolsWeb.MapLive.Public do
  use CAToolsWeb, :live_view
  import CAToolsWeb.MapComponents
  alias CATools.Maps

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 3_000)

    shared? = Map.has_key?(params, "id")

    map =
      if shared?,
        do: CATools.Communities.shared_map(socket.assigns.current_scope, params["id"]),
        else: Maps.get_public_map(params["slug"])

    case map do
      nil ->
        raise CAToolsWeb.NotFoundError

      map ->
        export_url =
          if shared?,
            do: ~p"/community/maps/#{map.id}/export.kml",
            else: ~p"/maps/#{map.public_slug}/export.kml"

        {:ok,
         assign(socket,
           map: map,
           points: Maps.point_data(map),
           page_title: map.name,
           shared?: shared?,
           export_url: export_url
         )}
    end
  end

  @impl true
  @doc false
  @spec handle_info(:refresh, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh, socket) do
    map =
      if socket.assigns.shared?,
        do: CATools.Communities.shared_map(socket.assigns.current_scope, socket.assigns.map.id),
        else: Maps.get_public_map(socket.assigns.map.public_slug)

    case map do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      map ->
        Process.send_after(self(), :refresh, 3_000)
        {:noreply, assign(socket, map: map, points: Maps.point_data(map), page_title: map.name)}
    end
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-wrap justify-between items-end gap-5 mb-8">
        <div>
          <h1 class="atlas-display text-3xl">
            {@map.name}
          </h1><p :if={@map.description not in [nil, ""]} class="mt-3 text-sm opacity-70 max-w-xl">
            {@map.description}
          </p>
        </div>
        <.link href={@export_url} download="campfire-map.kml" class="atlas-button"><.icon
          name="hero-arrow-down-tray"
          class="size-4"
        /> Export KML</.link>
      </div>
      <section class="atlas-card"><.map_canvas id="public-map" points={@points} /></section>
      <p class="text-xs opacity-60 mt-3">
        {length(@points)} meetup locations
      </p>
      <div :if={@points == []} class="atlas-empty mt-6">
        No locations yet.
      </div>
      <section class="grid md:grid-cols-3 gap-4 mt-8" aria-label="Meetup locations">
        <article :for={point <- @points} class="atlas-card p-5">
          <.meetup_image image_url={point.cover_photo_url} title={point.title} />
          <.meetup_host name={point.host_name} avatar_url={point.host_avatar_url} />
          <h2 class="font-semibold">
            {point.title}
          </h2>
          <p class="text-sm opacity-65 mt-2">{point.group_name}</p><p class="text-xs opacity-60 mt-2">
            {point.address}
          </p>
          <p :if={point.starts_at} class="text-xs mt-3">
            {Calendar.strftime(point.starts_at, "%d %b %Y · %H:%M UTC")}
          </p>
        </article>
      </section>
    </Layouts.app>
    """
  end
end
