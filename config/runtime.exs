import Config

if System.get_env("PHX_SERVER") do
  config :hex_mirror, HexMirrorWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :hex_mirror, HexMirrorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  if tarball_path = System.get_env("HEX_MIRROR_TARBALL_PATH") do
    config :hex_mirror, tarball_path: tarball_path
  end

  if max_bytes = System.get_env("HEX_MIRROR_MAX_BYTES") do
    config :hex_mirror, max_bytes: String.to_integer(max_bytes)
  end

  if keep = System.get_env("HEX_MIRROR_KEEP_VERSIONS") do
    config :hex_mirror, keep_versions: String.to_integer(keep)
  end

  if sweep = System.get_env("HEX_MIRROR_SWEEP_VERSIONS") do
    config :hex_mirror, sweep_versions: String.to_integer(sweep)
  end

  if ttl_days = System.get_env("HEX_MIRROR_UNUSED_TTL_DAYS") do
    config :hex_mirror, unused_ttl_seconds: String.to_integer(ttl_days) * 24 * 60 * 60
  end
end
