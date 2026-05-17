defmodule HexMirrorWeb.MirrorController do
  @moduledoc """
  Serves the raw signed registry payloads and tarballs that `mix` fetches from
  a hex mirror. Bytes are streamed straight from disk so signatures stay valid.
  """

  use HexMirrorWeb, :controller

  def public_key(conn, _params) do
    send_mirror_file(conn, HexMirror.public_key_path(), "application/x-pem-file")
  end

  def names(conn, _params) do
    send_mirror_file(conn, HexMirror.names_path(), "application/octet-stream")
  end

  def versions(conn, _params) do
    send_mirror_file(conn, HexMirror.versions_path(), "application/octet-stream")
  end

  def package(conn, %{"name" => name}) do
    send_mirror_file(conn, HexMirror.package_path(name), "application/octet-stream")
  end

  @hex_pm_tarballs "https://repo.hex.pm/tarballs"

  def tarball(conn, %{"tarball" => tarball}) do
    path = HexMirror.tarball_file_path(tarball)
    # Bump mtime on serve so HexMirror.Mirror.cleanup/1 can distinguish
    # actively consumed versions from cold ones when applying the usage TTL.
    # The `File.exists?` guard is required: `File.touch/1` creates the file
    # if missing, which would turn 404s into empty 200s and let an attacker
    # planting bogus path params seed empty tarballs into the store.
    if File.exists?(path) do
      _ = File.touch(path)
      send_mirror_file(conn, path, "application/octet-stream")
    else
      # Cache miss: redirect to hex.pm. The caller (mix) follows the 302 and
      # fetches directly. This makes the mirror fail-open: cache hits stay in
      # the VPC (no NAT cost), misses fall back transparently. The next sweep
      # will cache the version if it's within sweep_versions of the latest.
      redirect(conn, external: "#{@hex_pm_tarballs}/#{tarball}")
    end
  end

  defp send_mirror_file(conn, path, content_type) do
    if File.exists?(path) do
      conn
      |> put_resp_content_type(content_type)
      |> send_file(200, path)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "not found")
    end
  end
end
