defmodule HexMirror.MirrorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HexMirror.Mirror

  setup do
    tmp = Path.join(System.tmp_dir!(), "hex_mirror_mirror_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:hex_mirror, :tarball_path)
    Application.put_env(:hex_mirror, :tarball_path, tmp)
    File.mkdir_p!(HexMirror.tarballs_dir())

    on_exit(fn ->
      File.rm_rf!(tmp)

      if prev,
        do: Application.put_env(:hex_mirror, :tarball_path, prev),
        else: Application.delete_env(:hex_mirror, :tarball_path)
    end)

    {:ok, root: tmp}
  end

  defp write_tarball(name, version, mtime_seconds) do
    path = HexMirror.tarball_file_path("#{name}-#{version}.tar")
    File.write!(path, "#{name}-#{version}")
    {:ok, stat} = File.stat(path, time: :posix)
    :ok = File.write_stat(path, %{stat | mtime: mtime_seconds}, time: :posix)
    path
  end

  describe "select_newest_versions/2" do
    test "keep <= 0 is sentinel pass-through — returns all versions unchanged" do
      versions = ["1.0.0", "2.0.0", "1.5.0"]
      assert Mirror.select_newest_versions(versions, 0) == versions
      assert Mirror.select_newest_versions(versions, -1) == versions
    end

    test "returns newest N versions in descending semver order" do
      versions = ["1.0.0", "2.0.0", "1.5.0"]
      assert Mirror.select_newest_versions(versions, 2) == ["2.0.0", "1.5.0"]
    end

    test "returns all when keep >= length" do
      versions = ["1.0.0", "2.0.0"]
      assert Mirror.select_newest_versions(versions, 5) == ["2.0.0", "1.0.0"]
    end

    test "skips unparseable versions silently" do
      versions = ["1.0.0", "not-a-version", "2.0.0"]
      assert Mirror.select_newest_versions(versions, 2) == ["2.0.0", "1.0.0"]
    end

    test "handles pre-release semver ordering correctly" do
      # semver: 1.0.0 > 1.0.0-rc.1 > 0.9.0
      versions = ["1.0.0-rc.1", "1.0.0", "0.9.0"]
      assert Mirror.select_newest_versions(versions, 2) == ["1.0.0", "1.0.0-rc.1"]
    end

    test "empty input returns empty list" do
      assert Mirror.select_newest_versions([], 3) == []
    end
  end

  describe "changed_packages/2" do
    test "nil baseline (cold start) returns every package" do
      new_map = %{"foo" => {["1.0.0"], []}, "bar" => {["2.0.0"], []}}
      assert Enum.sort(Mirror.changed_packages(nil, new_map)) == ["bar", "foo"]
    end

    test "added package is included" do
      old = %{"foo" => {["1.0.0"], []}}
      new = %{"foo" => {["1.0.0"], []}, "bar" => {["0.1.0"], []}}
      assert Mirror.changed_packages(old, new) == ["bar"]
    end

    test "bumped version is included" do
      old = %{"foo" => {["1.0.0"], []}}
      new = %{"foo" => {["1.0.0", "1.1.0"], []}}
      assert Mirror.changed_packages(old, new) == ["foo"]
    end

    test "retirement-only change is included" do
      old = %{"foo" => {["1.0.0"], []}}
      new = %{"foo" => {["1.0.0"], [0]}}
      assert Mirror.changed_packages(old, new) == ["foo"]
    end

    test "unchanged package is excluded" do
      old = %{"foo" => {["1.0.0"], []}, "bar" => {["2.0.0"], []}}
      new = %{"foo" => {["1.0.0"], []}, "bar" => {["2.0.0"], []}}
      assert Mirror.changed_packages(old, new) == []
    end

    test "removed package is excluded (nothing to fetch)" do
      old = %{"foo" => {["1.0.0"], []}, "gone" => {["9.0.0"], []}}
      new = %{"foo" => {["1.0.0"], []}}
      assert Mirror.changed_packages(old, new) == []
    end

    test "empty new map returns empty" do
      assert Mirror.changed_packages(%{"foo" => {["1.0.0"], []}}, %{}) == []
    end
  end

  describe "versions baseline read/write roundtrip" do
    test "write then read returns the same map" do
      map = %{"foo" => {["1.0.0"], []}, "bar" => {["2.0.0", "2.1.0"], [0]}}
      assert Mirror.write_versions_baseline(map) == :ok
      assert Mirror.read_versions_baseline() == map
    end

    test "absent sidecar reads as nil (cold start)" do
      refute File.exists?(Mirror.versions_baseline_path())
      assert Mirror.read_versions_baseline() == nil
    end

    test "empty binary reads as nil" do
      File.write!(Mirror.versions_baseline_path(), <<>>)
      assert Mirror.read_versions_baseline() == nil
    end

    test "garbage (non-term) binary reads as nil" do
      File.write!(Mirror.versions_baseline_path(), "not-an-erlang-term")
      assert Mirror.read_versions_baseline() == nil
    end

    test "persisted empty map reads as nil (rejected by map_size guard)" do
      File.write!(Mirror.versions_baseline_path(), :erlang.term_to_binary(%{}))
      assert Mirror.read_versions_baseline() == nil
    end
  end

  describe "advance_baseline/2" do
    test "no failures persists the full new map" do
      new_map = %{"foo" => {["1.0.0"], []}, "bar" => {["2.0.0"], []}}
      assert Mirror.advance_baseline(new_map, []) == :ok
      assert Mirror.read_versions_baseline() == new_map
    end

    test "partial failure drops failed packages so they re-diff next sweep" do
      new_map = %{"foo" => {["1.0.0"], []}, "bar" => {["2.0.0"], []}}
      assert Mirror.advance_baseline(new_map, ["bar"]) == :ok

      baseline = Mirror.read_versions_baseline()
      assert baseline == %{"foo" => {["1.0.0"], []}}
      # `bar` is absent from the baseline → next diff sees it as "added".
      assert "bar" in Mirror.changed_packages(baseline, new_map)
      refute "foo" in Mirror.changed_packages(baseline, new_map)
    end

    test "all changed packages failing holds the existing baseline" do
      prior = %{"foo" => {["0.9.0"], []}}
      Mirror.write_versions_baseline(prior)

      new_map = %{"foo" => {["1.0.0"], []}}
      assert Mirror.advance_baseline(new_map, ["foo"]) == :ok
      # baseline_next would be empty ⇒ not written; prior baseline preserved.
      assert Mirror.read_versions_baseline() == prior
    end

    test "empty new map (degenerate payload) does not wipe the baseline" do
      prior = %{"foo" => {["1.0.0"], []}}
      Mirror.write_versions_baseline(prior)

      assert Mirror.advance_baseline(%{}, []) == :ok
      assert Mirror.read_versions_baseline() == prior
    end

    test "added package failing still logs the partial-baseline warning (no-op guard requires failed == [])" do
      prior = %{"foo" => {["1.0.0"], []}}
      Mirror.write_versions_baseline(prior)

      # `bar` newly published upstream but its fetch failed → baseline_next
      # coincidentally equals `prior`, but the failure must still be logged.
      new_map = %{"foo" => {["1.0.0"], []}, "bar" => {["2.0.0"], []}}

      log =
        capture_log(fn ->
          assert Mirror.advance_baseline(new_map, ["bar"]) == :ok
        end)

      assert log =~ "partial baseline"
      # baseline still excludes the failed package so it re-diffs next sweep.
      assert Mirror.read_versions_baseline() == prior
    end

    test "byte-identical baseline is not rewritten (no-op short-circuit)" do
      same = %{"foo" => {["1.0.0"], []}}
      path = Mirror.versions_baseline_path()
      Mirror.write_versions_baseline(same)

      # Stamp an old mtime; a real rewrite would bump it to ~now.
      old = :os.system_time(:second) - 10_000
      stat = File.stat!(path, time: :posix)
      :ok = File.write_stat(path, %{stat | mtime: old}, time: :posix)

      # advance with the identical map + no failures → should skip the write.
      assert Mirror.advance_baseline(same, []) == :ok

      assert File.stat!(path, time: :posix).mtime == old
      assert Mirror.read_versions_baseline() == same
    end
  end

  describe "cleanup/1 keep_versions" do
    test "keeps newest N semver, drops the rest" do
      now = :os.system_time(:second)
      write_tarball("foo", "1.0.0", now)
      write_tarball("foo", "1.1.0", now)
      write_tarball("foo", "2.0.0", now)
      write_tarball("foo", "0.5.0", now)

      :ok =
        Mirror.cleanup(
          keep_versions: 2,
          unused_ttl_seconds: 0,
          max_bytes: 1_000_000_000,
          now: now
        )

      remaining =
        HexMirror.tarballs_dir() |> File.ls!() |> Enum.sort()

      assert remaining == ["foo-1.1.0.tar", "foo-2.0.0.tar"]
    end
  end

  describe "cleanup/1 unused_ttl_seconds" do
    test "evicts stale-mtime versions but retains newest per package" do
      now = :os.system_time(:second)
      ttl = 100
      write_tarball("foo", "1.0.0", now - 500)
      write_tarball("foo", "1.1.0", now - 500)
      write_tarball("foo", "2.0.0", now - 500)

      :ok =
        Mirror.cleanup(
          keep_versions: 5,
          unused_ttl_seconds: ttl,
          max_bytes: 1_000_000_000,
          now: now
        )

      remaining = HexMirror.tarballs_dir() |> File.ls!() |> Enum.sort()
      # Newest semver kept as floor; older two evicted because mtime < now-ttl.
      assert remaining == ["foo-2.0.0.tar"]
    end

    test "retains versions touched within ttl" do
      now = :os.system_time(:second)
      ttl = 1_000
      write_tarball("foo", "1.0.0", now - 500)
      write_tarball("foo", "2.0.0", now - 500)

      :ok =
        Mirror.cleanup(
          keep_versions: 5,
          unused_ttl_seconds: ttl,
          max_bytes: 1_000_000_000,
          now: now
        )

      remaining = HexMirror.tarballs_dir() |> File.ls!() |> Enum.sort()
      assert remaining == ["foo-1.0.0.tar", "foo-2.0.0.tar"]
    end

    test "ttl=0 disables usage prune" do
      now = :os.system_time(:second)
      write_tarball("foo", "1.0.0", 1)
      write_tarball("foo", "2.0.0", 1)

      :ok =
        Mirror.cleanup(
          keep_versions: 5,
          unused_ttl_seconds: 0,
          max_bytes: 1_000_000_000,
          now: now
        )

      remaining = HexMirror.tarballs_dir() |> File.ls!() |> Enum.sort()
      assert remaining == ["foo-1.0.0.tar", "foo-2.0.0.tar"]
    end
  end

  describe "cleanup/1 floor invariant" do
    test "newest semver per package always survives even when every version is stale" do
      now = :os.system_time(:second)
      ttl = 100
      # All five versions are well past the TTL window.
      write_tarball("foo", "1.0.0", now - 10_000)
      write_tarball("foo", "1.1.0", now - 10_000)
      write_tarball("foo", "2.0.0", now - 10_000)
      write_tarball("foo", "2.5.0", now - 10_000)
      write_tarball("foo", "3.0.0", now - 10_000)

      :ok =
        Mirror.cleanup(
          keep_versions: 5,
          unused_ttl_seconds: ttl,
          max_bytes: 1_000_000_000,
          now: now
        )

      remaining = HexMirror.tarballs_dir() |> File.ls!() |> Enum.sort()
      assert remaining == ["foo-3.0.0.tar"]
    end
  end

  describe "cleanup/1 keep_versions <= 0" do
    test "treats keep_versions=0 as unlimited (does not delete everything)" do
      now = :os.system_time(:second)
      write_tarball("foo", "1.0.0", now)
      write_tarball("foo", "2.0.0", now)
      write_tarball("foo", "3.0.0", now)

      :ok =
        Mirror.cleanup(
          keep_versions: 0,
          unused_ttl_seconds: 0,
          max_bytes: 1_000_000_000,
          now: now
        )

      remaining = HexMirror.tarballs_dir() |> File.ls!() |> Enum.sort()
      assert remaining == ["foo-1.0.0.tar", "foo-2.0.0.tar", "foo-3.0.0.tar"]
    end
  end

  describe "cleanup/1 max_bytes" do
    test "evicts oldest mtime first to fit cap" do
      now = :os.system_time(:second)
      a = write_tarball("foo", "1.0.0", now - 300)
      b = write_tarball("foo", "2.0.0", now - 200)
      c = write_tarball("foo", "3.0.0", now - 100)

      total = File.stat!(a).size + File.stat!(b).size + File.stat!(c).size

      :ok =
        Mirror.cleanup(
          keep_versions: 5,
          unused_ttl_seconds: 0,
          max_bytes: total - 1,
          now: now
        )

      remaining = HexMirror.tarballs_dir() |> File.ls!() |> Enum.sort()
      assert "foo-1.0.0.tar" not in remaining
      assert "foo-3.0.0.tar" in remaining
    end
  end
end
