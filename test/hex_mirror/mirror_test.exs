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
