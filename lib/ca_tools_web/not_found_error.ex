defmodule CAToolsWeb.NotFoundError do
  @moduledoc "A resource is missing or unavailable to this viewer."
  defexception message: "Map not found", plug_status: 404
end
