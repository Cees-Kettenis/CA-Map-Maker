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

  attr :image_url, :string, default: nil
  attr :title, :string, required: true
  @doc "Renders an optional meetup cover image without sending the page URL to its host."
  @spec meetup_image(map()) :: Phoenix.LiveView.Rendered.t()
  def meetup_image(assigns) do
    assigns = assign(assigns, :image_url, CATools.Maps.ImageURL.normalize(assigns.image_url))

    ~H"""
    <img
      :if={@image_url}
      src={@image_url}
      alt={@title}
      loading="lazy"
      referrerpolicy="no-referrer"
      class="atlas-meetup-image"
    />
    """
  end

  attr :name, :string, default: nil
  attr :avatar_url, :string, default: nil
  @doc "Displays the meetup creator's name and optional profile picture."
  @spec meetup_host(map()) :: Phoenix.LiveView.Rendered.t()
  def meetup_host(assigns) do
    assigns = assign(assigns, :avatar_url, CATools.Maps.ImageURL.normalize(assigns.avatar_url))

    ~H"""
    <div :if={@name || @avatar_url} class="atlas-meetup-host">
      <img :if={@avatar_url} src={@avatar_url} alt="" loading="lazy" referrerpolicy="no-referrer" />
      <span>Hosted by <strong>{@name || "Campfire host"}</strong></span>
    </div>
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
