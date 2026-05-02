defmodule HexMirrorWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use HexMirrorWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import HexMirrorWeb.ConnCase

      @endpoint HexMirrorWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
