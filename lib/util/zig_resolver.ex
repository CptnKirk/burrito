defmodule Burrito.Util.ZigResolver do
  @moduledoc """
  Resolves a path to a `zig` executable matching Burrito's pinned version
  (see `Burrito.get_versions/0`), in this order:

    1. `BURRITO_ZIG_PATH` environment variable, if set — an explicit, always-trusted
       override.
    2. A previously downloaded, managed copy at the pinned version, if already cached.
    3. The system `zig` on `$PATH`, if its version matches the pinned version exactly —
       this preserves today's behavior unchanged for anyone who already has the right
       version installed.
    4. Otherwise, download the pinned version for the current host OS/CPU, verify its
       checksum, cache it, and use that.

  Only the exact pinned version is ever used to build — Burrito's own `build.zig`
  sources have historically only been compatible with one zig version at a time (see
  the 0.15 -> 0.16 migration), so accepting "any installed zig" isn't a safe
  relaxation of the old check. This resolver removes the need for the *system* to
  have zig installed at all, and stops an incompatible system zig from blocking a
  build, without weakening which zig version actually gets used.
  """

  alias Burrito.Builder.Log
  alias Burrito.Util

  # sha256 checksums for the pinned zig release, one per (os, cpu) Burrito supports
  # building on. Sourced from https://ziglang.org/download/index.json for the
  # version in Burrito.get_versions().zig -- update alongside that version.
  @zig_checksums %{
    {:linux, :x86_64} => "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
    {:linux, :aarch64} => "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
    {:darwin, :x86_64} => "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7",
    {:darwin, :aarch64} => "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
    {:windows, :x86_64} => "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e"
  }

  @spec resolve() :: {:ok, String.t()} | {:error, String.t()}
  def resolve do
    expected = Burrito.get_versions().zig

    with :miss <- from_override(),
         :miss <- from_managed_cache(expected),
         :miss <- from_system_path(expected) do
      download_and_cache(expected)
    end
  end

  @spec zig_version_at(String.t()) :: {:ok, Version.t()} | :error
  def zig_version_at(path) do
    case System.cmd(path, ["version"]) do
      {out, 0} -> {:ok, out |> String.trim() |> Version.parse!()}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp from_override do
    case System.get_env("BURRITO_ZIG_PATH") do
      nil ->
        :miss

      path ->
        if File.exists?(path) do
          Log.info(:step, "Using BURRITO_ZIG_PATH override: #{path}")
          {:ok, path}
        else
          {:error, "BURRITO_ZIG_PATH is set to `#{path}`, but no file exists there!"}
        end
    end
  end

  defp from_managed_cache(expected) do
    path = managed_zig_path(expected)

    if File.exists?(path) do
      Log.info(:step, "Using cached managed Zig #{expected}: #{path}")
      {:ok, path}
    else
      :miss
    end
  end

  defp from_system_path(expected) do
    case System.find_executable("zig") do
      nil ->
        :miss

      path ->
        case zig_version_at(path) do
          {:ok, ^expected} -> {:ok, path}
          _ -> :miss
        end
    end
  end

  defp download_and_cache(expected) do
    os = Util.get_current_os()
    cpu = Util.get_current_cpu()

    case Map.fetch(@zig_checksums, {os, cpu}) do
      :error ->
        {:error,
         "No managed Zig download is known for #{os}/#{cpu}. Install Zig #{expected} " <>
           "yourself and set BURRITO_ZIG_PATH to point at it."}

      {:ok, expected_sha256} ->
        Log.info(
          :step,
          "No compatible Zig found on PATH; fetching managed Zig #{expected} for #{os}/#{cpu}..."
        )

        fetch_and_install(os, cpu, expected, expected_sha256)
    end
  end

  defp fetch_and_install(os, cpu, version, expected_sha256) do
    {:ok, _} = Application.ensure_all_started(:req)

    archive_ext = if os == :windows, do: "zip", else: "tar.xz"
    file_name = "zig-#{cpu}-#{zig_os_name(os)}-#{version}.#{archive_ext}"
    url = "https://ziglang.org/download/#{version}/#{file_name}"

    Log.info(:step, "Downloading: #{url}")

    resp =
      case Util.get_proxy() do
        proxy = %{scheme: scheme, host: host, port: port} when scheme in ["http", "https"] ->
          Log.info(:step, "Using PROXY: #{proxy}")
          proxy = {String.to_atom(scheme), host, port, []}
          Req.get!(url, raw: true, connect_options: [proxy: proxy])

        _ ->
          Req.get!(url, raw: true)
      end

    cond do
      resp.status != 200 ->
        {:error, "Failed to download Zig from #{url} (got HTTP #{resp.status})"}

      sha256(resp.body) != expected_sha256 ->
        {:error,
         "Checksum mismatch for #{file_name}! Expected #{expected_sha256}, got " <>
           "#{sha256(resp.body)}. Refusing to use this download."}

      true ->
        install(resp.body, archive_ext, os, version)
    end
  end

  defp install(archive_bytes, archive_ext, os, version) do
    # Extract as a sibling of the final install location, not under System.tmp_dir!() --
    # that's frequently a separate filesystem (e.g. tmpfs) from the managed cache dir,
    # and File.rename!/2 (like POSIX rename(2)) cannot cross a device boundary.
    File.mkdir_p!(managed_root())

    extract_dir =
      Path.join(managed_root(), "extract-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(extract_dir)

    with :ok <- extract(archive_bytes, archive_ext, extract_dir),
         {:ok, unpacked_dir} <- sole_entry(extract_dir) do
      install_dir = managed_install_dir(version)
      File.mkdir_p!(Path.dirname(install_dir))
      File.rm_rf!(install_dir)
      File.rename!(unpacked_dir, install_dir)
      File.rm_rf!(extract_dir)

      zig_path = managed_zig_path(version)

      if os != :windows do
        File.chmod!(zig_path, 0o755)
      end

      Log.success(:step, "Installed managed Zig #{version}: #{zig_path}")
      {:ok, zig_path}
    else
      {:error, reason} ->
        File.rm_rf!(extract_dir)
        {:error, reason}
    end
  end

  defp extract(bytes, "tar.xz", dest_dir) do
    tmp_tar = Path.join(dest_dir, "archive.tar.xz")
    File.write!(tmp_tar, bytes)

    case System.cmd("tar", ["-xJf", tmp_tar, "-C", dest_dir]) do
      {_, 0} ->
        File.rm(tmp_tar)
        :ok

      {out, _} ->
        {:error, "Failed to extract Zig tarball: #{out}"}
    end
  end

  defp extract(bytes, "zip", dest_dir) do
    tmp_zip = Path.join(dest_dir, "archive.zip")
    File.write!(tmp_zip, bytes)

    case :zip.extract(String.to_charlist(tmp_zip), cwd: String.to_charlist(dest_dir)) do
      {:ok, _} ->
        File.rm(tmp_zip)
        :ok

      {:error, reason} ->
        {:error, "Failed to extract Zig archive: #{inspect(reason)}"}
    end
  end

  # The Zig archive always contains exactly one top-level `zig-<triplet>-<version>/`
  # directory (the compiler binary plus its supporting `lib/` sources) -- find it
  # rather than hardcoding its name, since the compression step wrote other files
  # (the archive itself) into the same scratch directory.
  defp sole_entry(dir) do
    case File.ls!(dir) |> Enum.reject(&(&1 in ["archive.tar.xz", "archive.zip"])) do
      [only] -> {:ok, Path.join(dir, only)}
      other -> {:error, "Expected exactly one entry in extracted Zig archive, got: #{inspect(other)}"}
    end
  end

  defp managed_install_dir(version) do
    os = Util.get_current_os()
    cpu = Util.get_current_cpu()
    Path.join([managed_root(), "#{version}-#{os}-#{cpu}"])
  end

  defp managed_zig_path(version) do
    exe = if Util.get_current_os() == :windows, do: "zig.exe", else: "zig"
    Path.join(managed_install_dir(version), exe)
  end

  defp managed_root do
    :filename.basedir(:user_cache, "burrito_file_cache") |> to_string() |> Path.join("zig")
  end

  defp zig_os_name(:darwin), do: "macos"
  defp zig_os_name(:windows), do: "windows"
  defp zig_os_name(:linux), do: "linux"

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
