# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`hex_mirror` is a self-hosted mirror of [hex.pm](https://hex.pm). It downloads the signed registry payloads and every package tarball to disk, then re-serves them **byte-identical** so upstream signatures keep verifying. Originally for [elixir.camp](http://elixir.camp) — offline venue, clients fetch deps with no internet.

Consumers point `mix` at it via `mix hex.config mirror_url http://<host>` (see README).

## Stack

- Elixir `~> 1.19`, OTP 28
- Phoenix `~> 1.8.5` + LiveView `~> 1.0`, Bandit adapter
- `:req` for HTTP, `:hex_core` (`:hex_registry`) for signed-payload decode
- No database, no Ecto. Disk is the only persistence.

## Commands

- `mix deps.get` — install deps.
- `mix phx.server` — boots endpoint **and** `HexMirror.MirrorWorker` (auto-sweeps every 60s). Default save dir `./tarballs/` — first sweep is many GB and many minutes.
- `mix fetch_packages` — one-shot mirror without web server. Starts `:req` and calls `HexMirror.Mirror.fetch/0`.
- `mix test` — controller tests for `MirrorController` and `PageController` exist (`test/hex_mirror_web/controllers/`). `HexMirror.Mirror` itself has no tests — treat changes there as untested.
- `mix format` — `.formatter.exs` is present.
- No CI (`.github/workflows/` empty), no `.credo.exs`, no `.tool-versions` — Elixir/OTP version not pinned by repo.

## Architecture

One OTP app (`HexMirror.Application`, `:one_for_one`) supervises:
`HexMirrorWeb.Telemetry`, `DNSCluster`, `Phoenix.PubSub` (`HexMirror.PubSub`), `HexMirrorWeb.Endpoint`, `HexMirror.MirrorWorker`.

### Mirroring side — `lib/hex_mirror/`

- `MirrorWorker` (GenServer): `Process.send_after(self(), :download, interval)` after each fetch returns. Default interval `:timer.minutes(1)`. Real cadence = `interval + sweep_duration`, not a strict minute.
- `Mirror.fetch/0` runs one sweep:
  1. `ensure_dirs/0` creates tarball root + `packages/` + `tarballs/` subdirs. Uses `:ok = File.mkdir_p(...)` — **intentionally crashes** on failure. Don't soften.
  2. Conditional GET `/public_key`, `/names`, `/versions` via `Req.get(..., decode_body: false, headers: If-None-Match/If-Modified-Since)`. Body written verbatim (signatures preserved); a sidecar `.meta` stores etag + last-modified for next sweep. 304 → reuse on-disk body. 200 → rewrite body + meta.
  3. `:hex_registry.decode_and_verify_signed/2` then `:hex_registry.decode_names/2` (repository `"hexpm"`) yield package list.
  4. For each package: conditional GET `/packages/<name>`, decode versions, then `Req.get("/tarballs/<name>-<ver>.tar")` for any tarball not already on disk (tarballs are immutable per name+version, so existence-on-disk is enough — no conditional GET).
- Errors are logged, not raised — bad payload aborts that step but the supervisor stays up. Sweep returns `{:error, reason}` on early failure (public key / names / versions).

### Serving side — `lib/hex_mirror_web/`

`HexMirrorWeb.Router` has two scopes. **Do not merge them.**

- `:browser` pipeline → `GET /` (`PageController`), `live "/packages"` (`PackagesLive`). HTML UI for humans.
- `:mirror_api` pipeline (just `accepts ["*/*"]`, no CSRF / sessions) → `MirrorController` actions:
  - `GET /public_key`
  - `GET /names`
  - `GET /versions`
  - `GET /packages/:name`
  - `GET /tarballs/:tarball`

These mirror_api routes are what `mix` actually hits. Adding `:browser` to them (CSRF, sessions) breaks `mix`. The browser `live "/packages"` and the API `/packages/:name` don't collide — different segment counts.

### Path resolution

All disk paths derive from `HexMirror.tarball_path/0`:
```elixir
Application.get_env(:hex_mirror, :tarball_path, Path.expand("./tarballs"))
```
Subpaths: `HexMirror.public_key_path/0`, `names_path/0`, `versions_path/0`, `packages_dir/0`, `tarballs_dir/0`. Override via `config :hex_mirror, tarball_path: "/path"` or `HEX_MIRROR_TARBALL_PATH` env (read in `config/runtime.exs`). Never hardcode a path elsewhere.

## Quirks

- Layout is the standard Phoenix 1.8 split (`lib/hex_mirror/` + `lib/hex_mirror_web/`). The legacy pre-1.3 `web/` tree was removed in the 1.8 upgrade — do not look for it.
- `Mirror.fetch/0` writes raw signed bodies with `decode_body: false`. Don't switch to default decoding — round-tripping JSON/protobuf would break upstream signature verification on re-serve.
- The sidecar `.meta` file is just `etag\nlast-modified`. If you change the format, `conditional_headers/1` must change too — the two are coupled.
- `code_reloading?` block in `Endpoint` adds `Phoenix.CodeReloader`; `mix.exs` also lists `listeners: [Phoenix.CodeReloader]` for project-wide reload. Both are needed for dev reload.
- README is the source of truth for the consumer-side workflow (`mix hex.config mirror_url ...`). Keep it in sync if you change ports or wire-protocol routes.
