import Config

config :hex_mirror, HexMirrorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "0V3Pu2zjV4f3rGzYqJ1m6lS2C8dN7sGbR8q2lZ4H8Yf3rGzYqJ1m6lS2C8dN7sGb",
  watchers: [],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/hex_mirror_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, debug_heex_annotations: true, enable_expensive_runtime_checks: true
