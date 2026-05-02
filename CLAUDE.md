# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`hex_mirror` is a Phoenix 1.2 / Elixir ~> 1.2 app that mirrors hex.pm: it downloads the registry and every package tarball to local disk and re-serves them so other developers (or CI) can run `mix hex.config mirror_url http://<this-host>` and pull deps from this mirror instead of repo.hex.pm.

This is a pre-Phoenix-1.3 layout: app code lives in **`web/`** (controllers/views/router/templates) and **`lib/`** (OTP app, supervisor, worker, mirror logic) — there is no `lib/hex_mirror_web/`. Do not "modernize" the layout casually; the project deliberately stays on the old structure.

## Commands

- `mix deps.get` — install deps. Phoenix 1.2 + cowboy 1.0 + httpoison 0.9 + `:hex` runtime app. Hex needs to be loaded as a runtime dep (`applications: [:hex, ...]`) so `Hex.Registry`/`Hex.Utils` are available at runtime.
- `mix phoenix.server` — boot the endpoint AND start `HexMirror.MirrorWorker`, which auto-mirrors every 60s. Default save dir: `./tarballs` (~700MB+).
- `mix fetch_packages` — one-shot mirror without booting the web server. Defined in `lib/tasks/fetch_packages.ex`; manually starts `HTTPoison` and `Hex` then calls `HexMirror.Mirror.fetch/0`.
- `mix test` — Phoenix-generated view tests only (`test/views/*`). There is no test coverage for the mirror logic; treat any change to `HexMirror.Mirror` as untested.
- No CI: `.github/workflows/` is empty. No formatter config, no credo config file (credo is a dep but unconfigured), no dialyzer.

## Architecture

Two cooperating concerns share one OTP app (`HexMirror`, supervisor strategy `:one_for_one`):

1. **Mirroring side** — `lib/hex_mirror/mirror_worker.ex` is a GenServer that `Process.send_after`s itself every 60s and calls `HexMirror.Mirror.fetch/0`. `Mirror.fetch` calls `Hex.Utils.ensure_registry!()` then iterates `Hex.Registry.all_packages()` and downloads every version via `HTTPoison.get("https://repo.hex.pm/tarballs/#{pkg}-#{ver}.tar")`. Idempotent: skips files that already exist on disk. Errors are printed but not raised — a bad download does not stop the sweep.
2. **Serving side** — `HexMirror.Endpoint` + `HexMirror.Router`. Two scopes:
   - Browser scope (`/`, `/packages`) — HTML pages backed by `PageController`/`PackagesController`.
   - Raw scope — `GET /registry.ets.gz` (RegistryController) and `GET /tarballs/:tarball` (TarballsController). These are the endpoints `mix` actually hits when a downstream uses this as `mirror_url`. Do not add the `:browser` pipeline (CSRF, sessions) to these — `mix` is not a browser.

The download directory is resolved by `HexMirror.Mirror.tarball_path/0`:
```
Application.get_env(:hex_mirror, :tarball_path, Path.expand("./tarballs"))
```
Override in `config/*.exs` with `config :hex_mirror, tarball_path: "/some/path"` — never hardcode the path elsewhere.

## Quirks worth knowing

- `ensure_tarball_dir/0` uses `:ok = File.mkdir_p(...)` — intentionally crashes on failure (commit 79e6412). Don't soften it.
- The worker schedules the *next* tick only after the previous fetch returns. A full mirror sweep can take many minutes, so the real cadence is "60s + sweep duration", not strictly every minute.
- README is the source of truth for the consumer-side workflow (`mix hex.config mirror_url ...` and how to unset it). Keep it in sync if you change ports/paths.
- No `.tool-versions`, `.formatter.exs`, or `.credo.exs` — Elixir/OTP version is not pinned by the repo. Use a Phoenix 1.2-compatible Elixir (1.2–1.6 era) or expect compile failures from this old Phoenix.
