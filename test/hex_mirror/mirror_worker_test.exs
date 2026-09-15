defmodule HexMirror.MirrorWorkerTest do
  use ExUnit.Case, async: true

  alias HexMirror.MirrorWorker

  describe "housekeeping_due?/2" do
    test "tick 0 is always due, regardless of cadence" do
      assert MirrorWorker.housekeeping_due?(0, 1)
      assert MirrorWorker.housekeeping_due?(0, 24)
      assert MirrorWorker.housekeeping_due?(0, 1080)
    end

    test "every_n_sweeps = 1 is due every tick (pre-decoupling default)" do
      assert MirrorWorker.housekeeping_due?(0, 1)
      assert MirrorWorker.housekeeping_due?(1, 1)
      assert MirrorWorker.housekeeping_due?(2, 1)
      assert MirrorWorker.housekeeping_due?(41, 1)
    end

    test "every_n_sweeps = 24 is due only on multiples of 24" do
      due_ticks = for tick <- 0..47, MirrorWorker.housekeeping_due?(tick, 24), do: tick
      assert due_ticks == [0, 24]
    end

    test "housekeeping_every <= 0 is treated as 1, not as disabled" do
      assert MirrorWorker.housekeeping_due?(0, 0)
      assert MirrorWorker.housekeeping_due?(1, 0)
      assert MirrorWorker.housekeeping_due?(0, -5)
      assert MirrorWorker.housekeeping_due?(3, -5)
    end
  end
end
