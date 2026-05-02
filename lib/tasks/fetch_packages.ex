defmodule Mix.Tasks.FetchPackages do
  @moduledoc "Fetch the hex.pm registry and every package tarball once, then exit."
  @shortdoc "Fetch packages"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)
    HexMirror.Mirror.fetch()
  end
end
