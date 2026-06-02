defmodule CATools.Repo do
  use Ecto.Repo,
    otp_app: :ca_tools,
    adapter: Ecto.Adapters.Postgres
end
