defmodule CAToolsWeb.MeetupImageController do
  @moduledoc "Serves locally stored meetup images, documented in /openapi.json."
  use CAToolsWeb, :controller

  @doc "Serves an existing cached image without contacting its original host. OpenAPI: cachedMeetupImage."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case CATools.Maps.ImageCache.file(id) do
      {:ok, path, type} ->
        conn
        |> put_resp_content_type(type)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_file(200, path)

      :error ->
        send_resp(conn, 404, "Image not found")
    end
  end
end
