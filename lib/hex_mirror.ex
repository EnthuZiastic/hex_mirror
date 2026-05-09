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
  @default_keep_versions 1
  @default_unused_ttl_seconds 30 * 24 * 60 * 60

  @doc "Hard cap on total tarball size after each sweep. Override via `HEX_MIRROR_MAX_BYTES`."
  def max_bytes, do: Application.get_env(:hex_mirror, :max_bytes, @default_max_bytes)

  @doc """
  Versions retained per package after cleanup AND the cap on how many newest
  versions a sweep will download. Override via `HEX_MIRROR_KEEP_VERSIONS`.
  """
  def keep_versions, do: Application.get_env(:hex_mirror, :keep_versions, @default_keep_versions)

  @doc """
  Tarballs untouched (neither freshly fetched nor served) for longer than this
  are evicted by `HexMirror.Mirror.cleanup/1`, regardless of `keep_versions`.
  The newest version of each package is always retained as a floor. Set `0` to
  disable. Override via `HEX_MIRROR_UNUSED_TTL_DAYS`.
  """
  def unused_ttl_seconds,
    do: Application.get_env(:hex_mirror, :unused_ttl_seconds, @default_unused_ttl_seconds)
end
