defmodule HexMirror.MirrorWorker do
  @moduledoc """
  Periodically refreshes the local mirror by calling `HexMirror.Mirror.fetch/0`.

  Schedules the next tick only after the current sweep returns, so the real
  cadence is `interval + sweep_duration`.
  """

  use GenServer

  require Logger

  @default_interval :timer.minutes(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_work(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:download, %{interval: interval} = state) do
    _ = HexMirror.Mirror.fetch()
    schedule_work(interval)
    {:noreply, state}
  end

  defp schedule_work(interval) do
    Process.send_after(self(), :download, interval)
  end
end
