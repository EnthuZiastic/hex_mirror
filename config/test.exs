import Config

config :hex_mirror, HexMirrorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TestSecretKeyBaseTestSecretKeyBaseTestSecretKeyBaseTestSecretKey",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
