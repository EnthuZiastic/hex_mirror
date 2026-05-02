import Config

config :hex_mirror,
  generators: [timestamp_type: :utc_datetime]

config :hex_mirror, HexMirrorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HexMirrorWeb.ErrorHTML, json: HexMirrorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HexMirror.PubSub,
  live_view: [signing_salt: "Tt5Qb1xK"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
