defmodule CAToolsWeb.MapController do
  @moduledoc "Map data and KML endpoints, documented in /openapi.json."
  use CAToolsWeb, :controller
  alias CATools.Maps
  alias CATools.Maps.KML

  @doc "Returns public-safe marker data for a public map. OpenAPI: publicMapPoints."
  @spec public_points(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def public_points(conn, %{"slug" => slug}) do
    case Maps.get_public_map(slug) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Map not found"})

      map ->
        json(conn, %{name: map.name, description: map.description, points: Maps.point_data(map)})
    end
  end

  @doc "Exports a public map without private source URLs. OpenAPI: publicMapKml."
  @spec public_export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def public_export(conn, %{"slug" => slug}) do
    case Maps.get_public_map(slug) do
      nil ->
        send_resp(conn, :not_found, "Map not found")

      map ->
        send_download(conn, {:binary, KML.generate(map)},
          filename: "campfire-map.kml",
          content_type: "application/vnd.google-earth.kml+xml"
        )
    end
  end

  @doc "Exports an owned map with its source links. OpenAPI: ownerMapKml."
  @spec owner_export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def owner_export(conn, %{"id" => id}) do
    case Maps.get_map(conn.assigns.current_scope, id) do
      nil ->
        send_resp(conn, :not_found, "Map not found")

      map ->
        send_download(conn, {:binary, KML.generate(map, true)},
          filename: "campfire-map.kml",
          content_type: "application/vnd.google-earth.kml+xml"
        )
    end
  end

  @doc "Exports an invitation-only community map for an authorized account. OpenAPI: communityMapKml."
  @spec community_export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def community_export(conn, %{"id" => id}) do
    case CATools.Communities.shared_map(conn.assigns.current_scope, id) do
      nil ->
        send_resp(conn, :not_found, "Map not found")

      map ->
        send_download(conn, {:binary, KML.generate(map)},
          filename: "community-map.kml",
          content_type: "application/vnd.google-earth.kml+xml"
        )
    end
  end
end
