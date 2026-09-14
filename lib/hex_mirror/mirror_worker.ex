defmodule HexMirror.MirrorWorker do
  @moduledoc """
  Periodically refreshes the local mirror by calling `HexMirror.Mirror.fetch/1`.

  Schedules the next tick only after the current sweep returns, so the real
  cadence is `interval + sweep_duration`.

  Every tick does the registry-refresh part of a sweep (cheap — O(changed
  packages) after the versions-diff). Only every `housekeeping_every`-th tick
  also does tarball-store housekeeping (mtime refresh + TTL/size-cap cleanup —
  the O(tarball-count) full-store walk; see `HexMirror.Mirror.fetch/1` and
  `HexMirror.housekeeping_every_n_sweeps/0`), decoupling that cost from the
  registry-freshness cadence CI depends on.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    # Config-driven defaults (see HexMirror.sweep_interval_ms/0 and
    # HexMirror.housekeeping_every_n_sweeps/0); opts override for tests.
    interval = Keyword.get(opts, :interval, HexMirror.sweep_interval_ms())

    housekeeping_every =
      Keyword.get(opts, :housekeeping_every, HexMirror.housekeeping_every_n_sweeps())

    schedule_work(interval)
    {:ok, %{interval: interval, housekeeping_every: housekeeping_every, tick: 0}}
  end

  @impl GenServer
  def handle_info(
        :download,
        %{interval: interval, housekeeping_every: housekeeping_every, tick: tick} = state
      ) do
    # Tick 0 (startup) always does housekeeping so a fresh pod's TTL/size-cap
    # pass runs immediately rather than waiting up to `housekeeping_every`
    # sweeps.
    housekeeping? = rem(tick, max(housekeeping_every, 1)) == 0
    _ = HexMirror.Mirror.fetch(housekeeping: housekeeping?)
    schedule_work(interval)
    {:noreply, %{state | tick: tick + 1}}
  end

  defp schedule_work(interval) do
    Process.send_after(self(), :download, interval)
  end
end
