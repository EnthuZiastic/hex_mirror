defmodule HexMirror.MirrorTest do
  use ExUnit.Case, async: false

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
