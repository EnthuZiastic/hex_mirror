defmodule HexMirrorWeb.PageController do
  use HexMirrorWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end
end
