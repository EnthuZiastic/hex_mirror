defmodule HexMirrorWeb.MirrorControllerTest do
  use HexMirrorWeb.ConnCase, async: false

  setup do
    tmp = Path.join(System.tmp_dir!(), "hex_mirror_test_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:hex_mirror, :tarball_path)
    Application.put_env(:hex_mirror, :tarball_path, tmp)
    File.mkdir_p!(Path.join(tmp, "tarballs"))
    File.mkdir_p!(Path.join(tmp, "packages"))

    on_exit(fn ->
      File.rm_rf!(tmp)

      if prev,
        do: Application.put_env(:hex_mirror, :tarball_path, prev),
        else: Application.delete_env(:hex_mirror, :tarball_path)
    end)

    {:ok, root: tmp}
  end

  test "GET /tarballs/:tarball serves the file", %{conn: conn, root: root} do
    File.write!(Path.join([root, "tarballs", "foo-1.0.0.tar"]), "tarball-bytes")
    conn = get(conn, ~p"/tarballs/foo-1.0.0.tar")
    assert response(conn, 200) == "tarball-bytes"
  end

  test "GET /tarballs/:tarball redirects to hex.pm when missing", %{conn: conn} do
    conn = get(conn, ~p"/tarballs/missing-9.9.9.tar")
    assert redirected_to(conn, 302) == "https://repo.hex.pm/tarballs/missing-9.9.9.tar"
  end

  test "GET /packages/:name serves the file", %{conn: conn, root: root} do
    File.write!(Path.join([root, "packages", "foo"]), "signed-package-payload")
    conn = get(conn, ~p"/packages/foo")
    assert response(conn, 200) == "signed-package-payload"
  end
end
