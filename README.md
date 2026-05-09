HexMirror
=========

A self-hosted mirror of [hex.pm](https://hex.pm). Downloads the signed registry
payloads (`/public_key`, `/names`, `/versions`, `/packages/<name>`) plus every
package tarball to disk, then re-serves them byte-identical so the upstream
signatures keep verifying.

Originally written for [elixir.camp](http://elixir.camp), where there is no
internet connection and clients need to fetch deps fully offline.

## Stack

- Elixir ~> 1.19, OTP 28
- Phoenix 1.8 + LiveView 1.0 (Bandit adapter)
- `:req` for HTTP, `:hex_core` for registry decode

## Instructions

```sh
mix deps.get
mix phx.server      # boots web server + MirrorWorker (sweeps every 60s)
# or one-shot, no web server:
mix fetch_packages
```

The first sweep downloads every published package tarball — expect many GB of
disk and a long initial run. Subsequent sweeps only fetch new releases.

Tarball storage defaults to `./tarballs`. Override per environment:

```elixir
# config/dev.exs
config :hex_mirror, tarball_path: "/some/big/disk/hex"
```

In production set `HEX_MIRROR_TARBALL_PATH` (see `config/runtime.exs`).

### Retention env vars (prod)

| Var | Default | Purpose |
|---|---|---|
| `HEX_MIRROR_TARBALL_PATH` | `./tarballs` | Root dir for the on-disk store. |
| `HEX_MIRROR_MAX_BYTES` | `5368709120` (5 GiB) | Hard cap on total tarball size. After every successful sweep, oldest-mtime tarballs are evicted until the total fits under this. |
| `HEX_MIRROR_KEEP_VERSIONS` | `1` | Newest N semver releases retained per package, **and** the cap on how many versions a sweep will download. Setting `0` or negative is treated as unlimited. |
| `HEX_MIRROR_UNUSED_TTL_DAYS` | `7` | Tarballs untouched (neither freshly fetched nor served) for this many days are evicted, except the single newest semver per package which is always retained as a floor. Set `0` to disable the TTL pass entirely. |

The full retention policy lives in `HexMirror.Mirror.cleanup/1` and runs after
every successful sweep. Failed sweeps (upstream unreachable / decode error)
skip cleanup so an outage cannot evict the keep-set.

## Pointing `mix` at this mirror

```sh
mix hex.config mirror_url http://localhost:4000
# revert to upstream:
mix hex.config mirror_url --delete
```

The mirror exposes the modern hex.pm wire protocol:

| Path | Purpose |
|---|---|
| `GET /public_key` | hex.pm signing pubkey |
| `GET /names` | signed list of all package names |
| `GET /versions` | signed list of all versions |
| `GET /packages/:name` | signed metadata + release list for `:name` |
| `GET /tarballs/:filename` | raw `pkg-version.tar` |

## TODO

- Parallel tarball downloads (current sweep is sequential)
- ETag / If-Modified-Since handling so sweeps only refetch changed packages
- Mirror hex installer
