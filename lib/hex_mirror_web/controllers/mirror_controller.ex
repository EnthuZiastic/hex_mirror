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

  def tarball(conn, %{"tarball" => tarball}) do
    send_mirror_file(conn, HexMirror.tarball_file_path(tarball), "application/octet-stream")
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
