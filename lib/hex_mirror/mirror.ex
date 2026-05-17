defmodule HexMirror.Mirror do
  @moduledoc """
  Downloads the hex.pm registry payloads and every package tarball to
  `HexMirror.tarball_path/0`. Raw signed payloads are saved verbatim so the
  mirror can re-serve byte-identical bytes (signatures preserved).

  Registry payloads (`/public_key`, `/names`, `/versions`, `/packages/<name>`)
  are revalidated each sweep with `If-None-Match` / `If-Modified-Since`. A 304
  reuses the on-disk body and skips downstream work; a 200 rewrites the body
  and the sidecar `.meta` (etag + last-modified) used on the next sweep.
  Tarballs are immutable per name+version, so existence on disk is enough.
  """

  require Logger

  @repo_url "https://repo.hex.pm"
  @repository "hexpm"

  @doc """
  Single sweep: refresh public key, /names, /versions, every /packages/<name>,
  then download any new tarballs. Idempotent — files already on disk are
  skipped, and conditional GETs avoid redownloading unchanged registry payloads.
  """
  def fetch do
    ensure_dirs()

    result =
      with {:ok, public_key, _} <- fetch_public_key(),
           {:ok, names_body, _} <- get_and_save("/names", HexMirror.names_path()),
           {:ok, _versions_body, versions_freshness} <-
             get_and_save("/versions", HexMirror.versions_path()) do
        handle_versions(versions_freshness, names_body, public_key)
      else
        {:error, reason} ->
          Logger.error("mirror sweep aborted: #{inspect(reason)}")
          {:error, reason}
      end

    case result do
      :ok ->
        cleanup()

      {:error, _} ->
        # Sweep failed (transport / decode error). Skip the TTL pass so a long
        # upstream outage on a fresh pod cannot evict the keep-set, and skip
        # the size cap so a misconfigured `max_bytes` cannot chew through the
        # store while we are blind to upstream state.
        :ok
    end

    result
  end

  @doc """
  Enforce retention policy on the tarball store. Three passes:

    1. Per-package: keep the newest `HexMirror.keep_versions/0` versions of each
       package (semver-ordered, descending). Older versions deleted.
    2. Usage TTL: of the survivors, evict any whose mtime is older than
       `HexMirror.unused_ttl_seconds/0`, except the single newest semver per
       package which is always retained as a floor. mtime is bumped on every
       fetch attempt and on every served request, so this evicts versions that
       are neither current targets nor actively consumed.
    3. Hard cap: if total tarball bytes still exceed `HexMirror.max_bytes/0`,
       evict by oldest mtime first until under cap.

  Errors are logged, not raised. Cleanup never aborts the sweep.

  Note: `fetch/0` only invokes `cleanup/1` when the sweep itself succeeded.
  A failed sweep (transport / decode error) skips cleanup entirely so an
  upstream outage on a fresh pod cannot evict the keep-set, and a
  misconfigured `max_bytes` cannot chew through the store while we are blind
  to upstream state. Manual `cleanup/1` callers always run all three passes.
  """
  def cleanup(opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, HexMirror.max_bytes())
    keep_versions = Keyword.get(opts, :keep_versions, HexMirror.keep_versions())
    ttl_seconds = Keyword.get(opts, :unused_ttl_seconds, HexMirror.unused_ttl_seconds())
    now = Keyword.get(opts, :now, :os.system_time(:second))

    survivors =
      keep_versions
      |> prune_old_versions()
      |> evict_unused(ttl_seconds, now)

    enforce_size_cap(survivors, max_bytes)
    :ok
  rescue
    err ->
      Logger.error("cleanup failed: #{inspect(err)}")
      {:error, err}
  end

  defp prune_old_versions(keep_versions) when keep_versions <= 0 do
    # `keep_versions <= 0` is treated as "unlimited" for symmetry with
    # `select_newest_versions/2` on the fetch side. Without this clause,
    # `Enum.split(_, 0)` would delete everything every sweep.
    list_tarball_entries(HexMirror.tarballs_dir())
  end

  defp prune_old_versions(keep_versions) do
    HexMirror.tarballs_dir()
    |> list_tarball_entries()
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {_name, entries} ->
      sorted = Enum.sort(entries, &version_desc/2)
      {keep, drop} = Enum.split(sorted, keep_versions)
      Enum.each(drop, &delete_entry/1)
      keep
    end)
  end

  defp evict_unused(entries, ttl_seconds, _now) when ttl_seconds <= 0, do: entries

  defp evict_unused(entries, ttl_seconds, now) do
    cutoff = now - ttl_seconds

    entries
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {_name, group} ->
      case Enum.sort(group, &version_desc/2) do
        [] ->
          []

        [newest | rest] ->
          kept_rest =
            Enum.filter(rest, fn entry ->
              if entry.mtime < cutoff do
                delete_entry(entry)
                false
              else
                true
              end
            end)

          [newest | kept_rest]
      end
    end)
  end

  defp enforce_size_cap(entries, max_bytes) do
    total = Enum.reduce(entries, 0, fn e, acc -> acc + e.size end)

    if total <= max_bytes do
      :ok
    else
      excess = total - max_bytes

      entries
      |> Enum.sort_by(& &1.mtime)
      |> Enum.reduce_while(0, fn entry, removed ->
        if removed >= excess do
          {:halt, removed}
        else
          delete_entry(entry)
          {:cont, removed + entry.size}
        end
      end)

      :ok
    end
  end

  defp list_tarball_entries(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(&parse_entry(dir, &1))

      {:error, _} ->
        []
    end
  end

  # Splits `<name>-<version>.tar` into (name, version). Anchored on the
  # trailing `.tar`, so the rightmost `<digit>+.<digit>+.<digit>+` segment
  # before `.tar` is treated as the version. Hex package names are
  # `[a-z][a-z0-9_]*` (no dots, no leading digits) so this anchor is
  # unambiguous in practice — the regex would only mis-split if a package
  # name itself ended in a semver-shaped suffix, which hex.pm's name policy
  # forbids.
  @filename_re ~r/^(?<name>.+)-(?<version>\d+\.\d+\.\d+(?:[+\-][^\/]*)?)\.tar$/
  defp parse_entry(dir, filename) do
    path = Path.join(dir, filename)

    with %{"name" => name, "version" => version_str} <-
           Regex.named_captures(@filename_re, filename),
         {:ok, version} <- Version.parse(version_str),
         {:ok, %File.Stat{size: size, mtime: mtime}} <- File.stat(path, time: :posix) do
      [
        %{
          path: path,
          name: name,
          version: version,
          size: size,
          mtime: mtime
        }
      ]
    else
      reason ->
        Logger.debug("parse_entry skipped #{filename}: #{inspect(reason)}")
        []
    end
  end

  defp version_desc(a, b), do: Version.compare(a.version, b.version) != :lt

  defp delete_entry(entry) do
    case File.rm(entry.path) do
      :ok ->
        Logger.debug("evicted #{entry.path}")
        :ok

      {:error, reason} ->
        Logger.warning("evict #{entry.path} failed: #{inspect(reason)}")
        :error
    end
  end

  defp handle_versions(:not_modified, _names_body, _public_key) do
    Logger.debug("/versions unchanged, skipping per-package sweep")
    # Refresh mtimes of every on-disk tarball whose mtime is already past the
    # half-window threshold, so the usage TTL pass treats a quiet upstream
    # (no new releases for `unused_ttl_seconds`) as healthy rather than as
    # evidence the keep-set is cold. Without this, a pre-populated PVC plus
    # a quiet week of 304s on `/versions` would let `evict_unused/3` wipe
    # everything except the floor-newest per package.
    refresh_stale_tarball_mtimes()
    :ok
  end

  defp handle_versions(:fresh, names_body, public_key) do
    case decode_names(names_body, public_key) do
      {:ok, package_names} ->
        Enum.each(package_names, &fetch_package(&1, public_key))
        :ok

      {:error, reason} ->
        Logger.error("mirror sweep aborted: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Walks every tarball on disk and bumps mtime *only* when it has aged past
  # half the usage-TTL window. This collapses the worst-case `:not_modified`
  # IO from `N touches × every sweep` (~14M utimensat syscalls/day on a 10k-
  # tarball PVC at 1-min sweep cadence) down to roughly `N / (ttl_seconds /
  # 2 / sweep_interval_seconds)` per sweep — i.e. each tarball is touched at
  # most once per half-window. Correctness still holds: as long as we touch
  # before mtime crosses `now - unused_ttl_seconds`, the TTL pass keeps the
  # entry. With a 7-day TTL (default) we have ~3.5 days of headroom between
  # the touch threshold and the eviction cutoff. When the TTL pass is
  # disabled (`unused_ttl_seconds <= 0`) the refresh is a no-op.
  defp refresh_stale_tarball_mtimes do
    case HexMirror.unused_ttl_seconds() do
      ttl when ttl <= 0 ->
        :ok

      ttl ->
        threshold = :os.system_time(:second) - div(ttl, 2)

        HexMirror.tarballs_dir()
        |> list_tarball_entries()
        |> Enum.each(fn entry ->
          if entry.mtime < threshold, do: _ = File.touch(entry.path)
        end)

        :ok
    end
  end

  defp ensure_dirs do
    :ok = File.mkdir_p(HexMirror.tarball_path())
    :ok = File.mkdir_p(HexMirror.packages_dir())
    :ok = File.mkdir_p(HexMirror.tarballs_dir())
  end

  defp fetch_public_key do
    case conditional_get("/public_key", HexMirror.public_key_path()) do
      {:ok, body, freshness} -> {:ok, body, freshness}
      other -> {:error, {:public_key, other}}
    end
  end

  defp get_and_save(path, save_to), do: conditional_get(path, save_to)

  defp conditional_get(path, save_to) do
    headers = conditional_headers(save_to)

    case Req.get(@repo_url <> path, decode_body: false, headers: headers) do
      {:ok, %Req.Response{status: 304}} ->
        case File.read(save_to) do
          {:ok, body} ->
            {:ok, body, :not_modified}

          {:error, reason} ->
            Logger.warning("304 for #{path} but cache unreadable: #{inspect(reason)}")
            {:error, {:cache_miss_after_304, path}}
        end

      {:ok, %Req.Response{status: 200, body: body} = resp} ->
        File.write!(save_to, body)
        write_meta(save_to, resp)
        {:ok, body, :fresh}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("GET #{path} returned status #{status}")
        {:error, {:status, status, path}}

      {:error, err} ->
        Logger.warning("GET #{path} failed: #{inspect(err)}")
        {:error, {:transport, err, path}}
    end
  end

  defp decode_names(body, public_key) do
    case :hex_registry.decode_and_verify_signed(maybe_gunzip(body), public_key) do
      {:ok, payload} ->
        case :hex_registry.decode_names(payload, @repository) do
          {:ok, %{packages: packages}} ->
            {:ok, Enum.map(packages, & &1.name)}

          err ->
            {:error, {:decode_names, err}}
        end

      err ->
        {:error, {:verify_names, err}}
    end
  end

  # hex.pm serves signed registry payloads gzipped. We persist the gzipped bytes
  # verbatim (so re-serve stays byte-identical and signatures verify upstream),
  # but must gunzip locally before handing to :hex_registry.
  defp maybe_gunzip(<<31, 139, 8, _::binary>> = body), do: :zlib.gunzip(body)
  defp maybe_gunzip(body), do: body

  defp fetch_package(name, public_key) do
    save_path = HexMirror.package_path(name)

    case get_and_save("/packages/#{name}", save_path) do
      {:ok, _body, :not_modified} -> :unchanged
      {:ok, body, :fresh} -> download_versions(body, name, public_key)
      _ -> :skip
    end
  end

  defp download_versions(body, name, public_key) do
    case decode_package(body, name, public_key) do
      {:ok, versions} ->
        # Download only the newest `sweep_versions` releases per sweep.
        # Decoupled from `keep_versions` so bandwidth stays bounded even when
        # version-count pruning is disabled (keep_versions=0 / TTL-only mode).
        versions
        |> select_newest_versions(HexMirror.sweep_versions())
        |> Enum.each(fn version -> fetch_tarball(name, version) end)

      {:error, reason} ->
        Logger.warning("decode package #{name} failed: #{inspect(reason)}")
    end
  end

  @doc false
  def select_newest_versions(versions, keep) when keep <= 0, do: versions

  @doc false
  def select_newest_versions(versions, keep) do
    versions
    |> Enum.flat_map(fn v ->
      case Version.parse(to_string(v)) do
        {:ok, parsed} ->
          [{parsed, v}]

        :error ->
          Logger.debug("select_newest_versions: unparseable version #{inspect(v)}")
          []
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> Version.compare(a, b) != :lt end)
    |> Enum.take(keep)
    |> Enum.map(fn {_parsed, original} -> original end)
  end

  defp decode_package(body, name, public_key) do
    with {:ok, payload} <-
           :hex_registry.decode_and_verify_signed(maybe_gunzip(body), public_key),
         {:ok, %{releases: releases}} <-
           :hex_registry.decode_package(payload, @repository, name) do
      {:ok, Enum.map(releases, & &1.version)}
    else
      err -> {:error, err}
    end
  end

  defp fetch_tarball(name, version) do
    filename = "#{name}-#{version}.tar"
    save_path = HexMirror.tarball_file_path(filename)

    if File.exists?(save_path) do
      # Bump mtime so the usage-TTL prune treats current target versions as
      # live. Without this, sweeps would never refresh mtime and ttl-evict
      # would drop versions we still consider part of `keep_versions`.
      _ = File.touch(save_path)
      :already_downloaded
    else
      Logger.info("downloading #{name} #{version}")

      case Req.get(@repo_url <> "/tarballs/#{filename}", decode_body: false) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          File.write!(save_path, body)
          :ok

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("tarball #{filename} status #{status}")
          {:error, {:status, status}}

        {:error, err} ->
          Logger.warning("tarball #{filename} error: #{inspect(err)}")
          {:error, err}
      end
    end
  end

  @doc "Names of every package present locally (best-effort, derived from /packages dir)."
  def local_packages do
    case File.ls(HexMirror.packages_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.ends_with?(&1, ".meta"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp meta_path(file), do: file <> ".meta"

  defp read_meta(file) do
    with true <- File.exists?(file),
         {:ok, bin} <- File.read(meta_path(file)) do
      safe_term(bin)
    else
      _ -> %{}
    end
  end

  defp safe_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> %{}
  end

  defp write_meta(file, %Req.Response{} = resp) do
    meta = %{
      etag: header(resp, "etag"),
      last_modified: header(resp, "last-modified")
    }

    File.write!(meta_path(file), :erlang.term_to_binary(meta))
  end

  defp conditional_headers(save_to) do
    meta = read_meta(save_to)

    []
    |> maybe_put("if-none-match", Map.get(meta, :etag))
    |> maybe_put("if-modified-since", Map.get(meta, :last_modified))
  end

  defp maybe_put(headers, _name, nil), do: headers
  defp maybe_put(headers, _name, ""), do: headers
  defp maybe_put(headers, name, value), do: [{name, value} | headers]

  defp header(%Req.Response{} = resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      _ -> nil
    end
  end
end
