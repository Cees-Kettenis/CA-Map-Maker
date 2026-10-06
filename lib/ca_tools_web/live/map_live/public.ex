defmodule CAToolsWeb.MapLive.Public do
  use CAToolsWeb, :live_view
  import CAToolsWeb.MapComponents
  alias CATools.Maps

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(params, _session, socket) do
    shared? = Map.has_key?(params, "id")

    map =
      if shared?,
        do: CATools.Communities.shared_map(socket.assigns.current_scope, params["id"]),
        else: Maps.get_public_map(params["slug"])

    case map do
      nil ->
        raise CAToolsWeb.NotFoundError

      map ->
        if connected?(socket), do: Maps.subscribe(map.user_id)

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
           show_past?: false,
           view_time: DateTime.utc_now(),
           expiry_timer: if(connected?(socket), do: Maps.schedule_expiry(map.points)),
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
        {:noreply,
         assign(socket,
           map: map,
           points: Maps.point_data(map),
           page_title: map.name,
           view_time: DateTime.utc_now(),
           expiry_timer: Maps.schedule_expiry(map.points, socket.assigns.expiry_timer)
         )}
    end
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_past", _params, socket),
    do: {:noreply, assign(socket, show_past?: !socket.assigns.show_past?)}

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-wrap justify-between items-center gap-3 mb-4 sm:gap-5 sm:mb-8">
        <.map_identity map={@map} />
        <.link href={@export_url} download="pogo-meetups-map.kml" class="atlas-button"><.icon
          name="hero-arrow-down-tray"
          class="size-4"
        /> Export KML</.link>
      </div>
      <section class="atlas-card">
        <.map_canvas id="public-map" points={@points} now={@view_time} />
      </section>
      <p class="text-xs opacity-60 mt-3">
        {length(Maps.active_points(@points, @view_time))} meetup locations
      </p>
      <.meetup_section id="public-meetups" points={@points} show_past={@show_past?} now={@view_time} />
    </Layouts.app>
    """
  end
end
