defmodule CollaborativeWebsocket.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CollaborativeWebsocketWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:collaborative_websocket, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CollaborativeWebsocket.PubSub},
      # Start our session state workers
      CollaborativeWebsocket.SessionState,
      CollaborativeWebsocket.ReliableSessionState,
      # Start reliability monitoring agent
      %{
        id: CollaborativeWebsocket.ReliabilityMonitor,
        start: {Agent, :start_link, [fn -> %{} end, [name: CollaborativeWebsocket.ReliabilityMonitor]]}
      },
      # Start to serve requests, typically the last entry
      CollaborativeWebsocketWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CollaborativeWebsocket.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CollaborativeWebsocketWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
