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
end
