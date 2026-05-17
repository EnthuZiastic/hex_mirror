defmodule HexMirrorWeb.MirrorController do
  @moduledoc """
  Serves the raw signed registry payloads and tarballs that `mix` fetches from
  a hex mirror. Bytes are streamed straight from disk so signatures stay valid.
  """

  use HexMirrorWeb, :controller

  require Logger

  # Only redirect for well-formed <package>-<version>.tar names. Rejects path
  # traversal and arbitrary garbage before it reaches hex.pm, keeping the
  # redirect surface bounded to legitimate tarball requests.
  @tarball_re ~r/^[a-z][a-z0-9_]*-\d+\.\d+\.\d+[^\/?#]*\.tar$/

  @hex_pm_tarballs "https://repo.hex.pm/tarballs"

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

  def tarball(conn, %{"tarball" => tarball}) do
    path = HexMirror.tarball_file_path(tarball)
    # Bump mtime on serve so HexMirror.Mirror.cleanup/1 can distinguish
    # actively consumed versions from cold ones when applying the usage TTL.
    # The `File.exists?` guard is required: `File.touch/1` creates the file
    # if missing, which would turn 404s into empty 200s and let an attacker
    # plant bogus path params and seed empty tarballs into the store.
    if File.exists?(path) do
      _ = File.touch(path)
      send_mirror_file(conn, path, "application/octet-stream")
    else
      redirect_or_reject(conn, tarball)
    end
  end

  # Cache miss: redirect client directly to hex.pm so mix can fetch the
  # tarball without failing. Cache hits stay in-VPC (no NAT cost); misses pay
  # NAT only on that request. Versions older than sweep_versions of the latest
  # are *permanent* cache misses — the redirect is the steady state for pinned
  # old deps, not a transient. Log each miss so NAT cost remains observable.
  defp redirect_or_reject(conn, tarball) do
    if Regex.match?(@tarball_re, tarball) do
      Logger.info("[hex-mirror] cache miss: #{tarball}")
      redirect(conn, external: "#{@hex_pm_tarballs}/#{tarball}")
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "not found")
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
