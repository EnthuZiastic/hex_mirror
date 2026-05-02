defmodule HexMirror.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      HexMirrorWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hex_mirror, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: HexMirror.PubSub},
      HexMirrorWeb.Endpoint,
      HexMirror.MirrorWorker
    ]

    opts = [strategy: :one_for_one, name: HexMirror.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    HexMirrorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
