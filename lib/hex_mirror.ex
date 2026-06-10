defmodule HexMirror do
  @moduledoc """
  HexMirror context: tarball path resolution and storage layout helpers.

  Storage layout under `tarball_path/0`:

      <root>/public_key
      <root>/names
      <root>/versions
      <root>/packages/<name>
      <root>/tarballs/<name>-<version>.tar
  """

  @doc "Root directory holding the mirror payloads."
  def tarball_path do
    Application.get_env(:hex_mirror, :tarball_path, Path.expand("./tarballs"))
  end

  def packages_dir, do: Path.join(tarball_path(), "packages")
  def tarballs_dir, do: Path.join(tarball_path(), "tarballs")
  def public_key_path, do: Path.join(tarball_path(), "public_key")
  def names_path, do: Path.join(tarball_path(), "names")
  def versions_path, do: Path.join(tarball_path(), "versions")

  def package_path(name), do: Path.join(packages_dir(), name)
  def tarball_file_path(filename), do: Path.join(tarballs_dir(), filename)

  @default_max_bytes 5 * 1024 * 1024 * 1024
  @default_keep_versions 0
  @default_sweep_versions 2
  @default_unused_ttl_seconds 7 * 24 * 60 * 60
  @default_sweep_interval_ms 60_000
  @default_prefetch_tarballs true

  @doc "Hard cap on total tarball size after each sweep. Override via `HEX_MIRROR_MAX_BYTES`."
  def max_bytes, do: Application.get_env(:hex_mirror, :max_bytes, @default_max_bytes)

  @doc """
  Max versions per package retained by the version-count prune pass in cleanup.
  `0` (default) disables version-count pruning entirely — retention is governed
  solely by `unused_ttl_seconds` and `max_bytes`. Override via `HEX_MIRROR_KEEP_VERSIONS`.
  """
  def keep_versions, do: Application.get_env(:hex_mirror, :keep_versions, @default_keep_versions)

  @doc """
  Max versions per package downloaded per sweep. Decoupled from `keep_versions`
  so the sweep stays bandwidth-bounded even when version-count pruning is disabled.
  `0` means unlimited (download all historical versions — use with caution).
  Override via `HEX_MIRROR_SWEEP_VERSIONS`.
  """
  def sweep_versions,
    do: Application.get_env(:hex_mirror, :sweep_versions, @default_sweep_versions)

  @doc """
  Tarballs untouched (neither freshly fetched nor served) for longer than this
  are evicted by `HexMirror.Mirror.cleanup/1`, regardless of `keep_versions`.
  The newest version of each package is always retained as a floor. Set `0` to
  disable. Override via `HEX_MIRROR_UNUSED_TTL_DAYS`.
  """
  def unused_ttl_seconds,
    do: Application.get_env(:hex_mirror, :unused_ttl_seconds, @default_unused_ttl_seconds)

  @doc """
  Interval between mirror sweeps, in milliseconds. The real cadence is
  `interval + sweep_duration` (the worker schedules the next tick only after the
  current sweep returns). Each sweep walks the `/packages/<name>` registry index
  and stat-walks the tarball store, so on a shared/metered filesystem (e.g. EFS)
  the interval is the dominant lever on background IO cost. Default 60_000 (1 min)
  preserves historical behavior; raise it (e.g. 30 min) where IO is metered.
  Override via `HEX_MIRROR_SWEEP_INTERVAL_MINUTES`.
  """
  def sweep_interval_ms,
    do: Application.get_env(:hex_mirror, :sweep_interval_ms, @default_sweep_interval_ms)

  @doc """
  When `true` (default), each sweep eagerly downloads the newest `sweep_versions`
  tarballs of *every* package in the hex.pm registry — a full mirror. When
  `false`, the sweep still refreshes the registry index (`/names`, `/versions`,
  `/packages/<name>`) so dependency resolution stays current, but skips eager
  tarball downloads; tarballs are served on demand (cache hit from disk, miss
  redirects to hex.pm — see `HexMirrorWeb.MirrorController`). Set `false` to run
  as a lazy pull-through cache instead of a full registry mirror.
  Override via `HEX_MIRROR_PREFETCH_TARBALLS`.
  """
  def prefetch_tarballs?,
    do: Application.get_env(:hex_mirror, :prefetch_tarballs, @default_prefetch_tarballs)
end
