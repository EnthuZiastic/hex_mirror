defmodule HexMirrorWeb.Router do
  use HexMirrorWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {HexMirrorWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :mirror_api do
    plug(:accepts, ["*/*"])
  end

  scope "/", HexMirrorWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    live("/packages", PackagesLive, :index)
  end

  # Hex client endpoints — no browser pipeline (mix is not a browser).
  scope "/", HexMirrorWeb do
    pipe_through(:mirror_api)

    get("/public_key", MirrorController, :public_key)
    get("/names", MirrorController, :names)
    get("/versions", MirrorController, :versions)
    get("/packages/:name", MirrorController, :package)
    get("/tarballs/:tarball", MirrorController, :tarball)
  end
end
