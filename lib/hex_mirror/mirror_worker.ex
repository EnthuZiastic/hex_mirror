defmodule HexMirror.MirrorWorker do
  @moduledoc """
  Periodically refreshes the local mirror by calling `HexMirror.Mirror.fetch/1`.

  Schedules the next tick only after the current sweep returns, so the real
  cadence is `interval + sweep_duration`.

  Every tick does the registry-refresh part of a sweep (cheap — O(changed
  packages) after the versions-diff). Only every `housekeeping_every`-th tick
  also does tarball-store housekeeping (mtime refresh + TTL/size-cap cleanup —
  the O(tarball-count) full-store walk; see `HexMirror.Mirror.fetch/1` and
  `HexMirror.housekeeping_every_n_sweeps/0`, including the `max_bytes`
  enforcement-latency tradeoff this introduces), decoupling that cost from
  the registry-freshness cadence CI depends on.

  The tick counter is process state, not persisted — it resets to 0 on every
  restart of this GenServer (pod restart, deploy, crash). See
  `HexMirror.housekeeping_every_n_sweeps/0` for what that means for the
  realized cadence.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether tick `tick` (0-indexed) should run housekeeping, given a
  `housekeeping_every`-sweep cadence. Tick 0 always runs it — the first
  sweep after this GenServer starts (whether that's pod startup or any
  later restart) runs housekeeping rather than waiting up to
  `housekeeping_every` sweeps; it is NOT run before the first sweep fires,
  i.e. not synchronously at process init — see `init/1`, which schedules the
  first tick `interval` ms out like every other tick.

  `housekeeping_every <= 0` is treated as `1` (housekeeping every tick,
  the pre-decoupling default) rather than "disabled" — consistent with how
  `HexMirror.keep_versions/0` and `HexMirror.unused_ttl_seconds/0` treat
  `<= 0` as their own "no-op the pass" sentinel elsewhere in this app, but
  note it is the *opposite* convention here: `0` does not turn housekeeping
  off, it maximizes its frequency.
  """
  @spec housekeeping_due?(non_neg_integer(), integer()) :: boolean()
  def housekeeping_due?(tick, housekeeping_every) do
    rem(tick, max(housekeeping_every, 1)) == 0
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
    housekeeping? = housekeeping_due?(tick, housekeeping_every)
    _ = HexMirror.Mirror.fetch(housekeeping: housekeeping?)
    schedule_work(interval)
    {:noreply, %{state | tick: tick + 1}}
  end

  defp schedule_work(interval) do
    Process.send_after(self(), :download, interval)
  end
end
