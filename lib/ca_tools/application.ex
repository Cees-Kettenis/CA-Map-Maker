defmodule CATools.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  @doc false
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      CAToolsWeb.Telemetry,
      CATools.Repo,
      {DNSCluster, query: Application.get_env(:ca_tools, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CATools.PubSub},
      # Start a worker by calling: CATools.Worker.start_link(arg)
      # {CATools.Worker, arg},
      # Start to serve requests, typically the last entry
      CAToolsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CATools.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  @doc false
  @spec config_change(keyword(), keyword(), keyword()) :: :ok
  def config_change(changed, _new, removed) do
    CAToolsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
