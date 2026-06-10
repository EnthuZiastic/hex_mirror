defmodule HexMirrorTest do
  use ExUnit.Case, async: false

  # Config accessors that gate the sweep cadence (filesystem IO cost) and the
  # eager-mirror-vs-lazy-cache behavior. Defaults must preserve historical
  # behavior (1-minute sweep, full eager mirror) so existing deployments are
  # unaffected; environments opt into throttling/laziness via env vars.

  describe "sweep_interval_ms/0" do
    setup do
      prev = Application.get_env(:hex_mirror, :sweep_interval_ms)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:hex_mirror, :sweep_interval_ms, prev),
          else: Application.delete_env(:hex_mirror, :sweep_interval_ms)
      end)
    end

    test "defaults to 60_000 ms (1 minute) when unset" do
      Application.delete_env(:hex_mirror, :sweep_interval_ms)
      assert HexMirror.sweep_interval_ms() == 60_000
    end

    test "reads the configured value" do
      Application.put_env(:hex_mirror, :sweep_interval_ms, 30 * 60 * 1000)
      assert HexMirror.sweep_interval_ms() == 1_800_000
    end
  end

  describe "prefetch_tarballs?/0" do
    setup do
      prev = Application.get_env(:hex_mirror, :prefetch_tarballs)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:hex_mirror, :prefetch_tarballs),
          else: Application.put_env(:hex_mirror, :prefetch_tarballs, prev)
      end)
    end

    test "defaults to true (full eager mirror) when unset" do
      Application.delete_env(:hex_mirror, :prefetch_tarballs)
      assert HexMirror.prefetch_tarballs?() == true
    end

    test "honors false (lazy pull-through cache)" do
      Application.put_env(:hex_mirror, :prefetch_tarballs, false)
      assert HexMirror.prefetch_tarballs?() == false
    end
  end
end
