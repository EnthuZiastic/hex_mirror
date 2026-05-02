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
  end

  defp handle_versions(:not_modified, _names_body, _public_key) do
    Logger.debug("/versions unchanged, skipping per-package sweep")
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
    case :hex_registry.decode_and_verify_signed(body, public_key) do
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
        Enum.each(versions, fn version -> fetch_tarball(name, version) end)

      {:error, reason} ->
        Logger.warning("decode package #{name} failed: #{inspect(reason)}")
    end
  end

  defp decode_package(body, name, public_key) do
    with {:ok, payload} <- :hex_registry.decode_and_verify_signed(body, public_key),
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
