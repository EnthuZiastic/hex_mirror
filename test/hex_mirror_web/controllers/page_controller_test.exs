defmodule HexMirrorWeb.PageControllerTest do
  use HexMirrorWeb.ConnCase, async: true

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "HexMirror"
  end
end
