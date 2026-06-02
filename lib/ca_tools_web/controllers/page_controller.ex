defmodule CAToolsWeb.PageController do
  use CAToolsWeb, :controller

  @doc "Renders the landing page."
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    render(conn, :home)
  end
end
