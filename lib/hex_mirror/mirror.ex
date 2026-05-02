defmodule HexMirror.Mirror do
  @moduledoc """
  Downloads the hex.pm registry payloads and every package tarball to
  `HexMirror.tarball_path/0`. Raw signed payloads are saved verbatim so the
  mirror can re-serve byte-identical bytes (signatures preserved).
  """

  require Logger

  @repo_url "https://repo.hex.pm"
  @repository "hexpm"

  @doc """
  Single sweep: refresh public key, /names, /versions, every /packages/<name>,
  then download any new tarballs. Idempotent — files already on disk are skipped.
  """
  def fetch do
    ensure_dirs()

    with {:ok, public_key} <- fetch_public_key(),
         {:ok, names_body} <- get_and_save("/names", HexMirror.names_path()),
         {:ok, _versions_body} <- get_and_save("/versions", HexMirror.versions_path()),
         {:ok, package_names} <- decode_names(names_body, public_key) do
      Enum.each(package_names, &fetch_package(&1, public_key))
      :ok
    else
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
    case Req.get(@repo_url <> "/public_key", decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.write!(HexMirror.public_key_path(), body)
        {:ok, body}

      other ->
        {:error, {:public_key, other}}
    end
  end

  defp get_and_save(path, save_to) do
    case Req.get(@repo_url <> path, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.write!(save_to, body)
        {:ok, body}

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
      {:ok, body} ->
        case decode_package(body, name, public_key) do
          {:ok, versions} ->
            Enum.each(versions, fn version -> fetch_tarball(name, version) end)

          {:error, reason} ->
            Logger.warning("decode package #{name} failed: #{inspect(reason)}")
        end

      _ ->
        :skip
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
      {:ok, entries} -> Enum.sort(entries)
      _ -> []
    end
  end
end
