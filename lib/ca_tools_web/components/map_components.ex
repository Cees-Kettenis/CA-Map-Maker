defmodule CAToolsWeb.MapComponents do
  @moduledoc "Shared geographic map and point components."
  use CAToolsWeb, :html

  @external_resource Path.expand("../../../priv/static/images/atlas-map.svg", __DIR__)
  @map_illustration File.read!(@external_resource)

  @doc "Renders the local SVG illustration inline so its route and pins can be animated."
  @spec map_illustration(map()) :: Phoenix.LiveView.Rendered.t()
  def map_illustration(assigns) do
    assigns = assign(assigns, :illustration, @map_illustration)

    ~H"""
    <div class="atlas-hero-art" aria-hidden="true">{Phoenix.HTML.raw(@illustration)}</div>
    """
  end

  attr :id, :string, required: true
  attr :points, :list, required: true
  @doc "Renders a Leaflet map with escaped JSON and a stable canvas."
  @spec map_canvas(map()) :: Phoenix.LiveView.Rendered.t()
  def map_canvas(assigns) do
    assigns =
      assign(
        assigns,
        :tile_url,
        Application.get_env(
          :ca_tools,
          :map_tile_url,
          "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        )
      )

    ~H"""
    <div id={@id} phx-hook="AtlasMap" data-tile-url={@tile_url}>
      <div
        id={@id <> "-canvas"}
        phx-update="ignore"
        data-map-canvas
        class="atlas-map"
        role="region"
        aria-label="Map of meetup locations"
      >
      </div>
      <span hidden data-map-points>{Jason.encode!(@points)}</span>
    </div>
    """
  end
end
