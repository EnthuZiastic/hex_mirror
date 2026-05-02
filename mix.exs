defmodule HexMirror.MixProject do
  use Mix.Project

  def project do
    [
      app: :hex_mirror,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {HexMirror.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.5"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:dns_cluster, "~> 0.1"},
      {:req, "~> 0.5"},
      {:hex_core, "~> 0.11"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
