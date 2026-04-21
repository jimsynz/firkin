defmodule Mix.Tasks.Firkin.Serve do
  @shortdoc "Starts a Firkin HTTP server for manual testing"

  @moduledoc """
  Starts a Bandit HTTP server serving `Firkin.Plug`, suitable for
  poking at Firkin with `aws` CLI, `mc`, or any other S3 client.

  ## Usage

      mix firkin.serve [options]

  ## Options

    * `--port` — listen port (default: `4566`)
    * `--bind` — listen IP (default: `127.0.0.1`; use `0.0.0.0` to
      accept external connections)
    * `--hostname` — base hostname for virtual-hosted-style addressing.
      When set, requests to `Host: bucket.<hostname>` extract the
      bucket from the host header. Path-style continues to work.
      (default: unset — path-style only)
    * `--region` — AWS region string for SigV4 and GetBucketLocation
      (default: `us-east-1`)
    * `--backend` — fully-qualified backend module (default:
      `Firkin.Backends.Memory`). Any module implementing
      `Firkin.Backend` works.
    * `--access-key` — access key for the seeded credential when using
      the default memory backend (default: `firkin`)
    * `--secret-key` — secret key for the seeded credential when using
      the default memory backend (default: `firkin-secret`)

  When `--backend` is set to anything other than the memory backend
  `--access-key` / `--secret-key` are ignored; credential setup is the
  backend's responsibility.

  ## Example

      $ mix firkin.serve --port 9000
      Firkin listening on http://localhost:9000/

        AWS_ACCESS_KEY_ID=firkin \\
        AWS_SECRET_ACCESS_KEY=firkin-secret \\
        aws --endpoint-url=http://localhost:9000 s3 mb s3://demo
  """

  use Mix.Task

  alias Firkin.Backends.Memory

  @default_backend Memory

  @switches [
    port: :integer,
    bind: :string,
    hostname: :string,
    region: :string,
    backend: :string,
    access_key: :string,
    secret_key: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    port = Keyword.get(opts, :port, 4566)
    bind = opts |> Keyword.get(:bind, "127.0.0.1") |> parse_ip!()
    hostname = Keyword.get(opts, :hostname)
    region = Keyword.get(opts, :region, "us-east-1")
    backend = opts |> Keyword.get(:backend) |> resolve_backend()
    access_key = Keyword.get(opts, :access_key, "firkin")
    secret_key = Keyword.get(opts, :secret_key, "firkin-secret")

    ensure_backend_loaded!(backend)
    maybe_seed_memory_backend(backend, access_key, secret_key)

    plug_opts =
      [backend: backend, region: region]
      |> then(fn kw -> if hostname, do: Keyword.put(kw, :hostname, hostname), else: kw end)

    {:ok, _} =
      Bandit.start_link(
        plug: {Firkin.Plug, plug_opts},
        port: port,
        ip: bind,
        startup_log: false
      )

    Mix.shell().info(banner(bind, port, backend, access_key, secret_key, hostname))

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  defp resolve_backend(nil), do: @default_backend

  defp resolve_backend(name) when is_binary(name) do
    Module.concat([name])
  end

  defp ensure_backend_loaded!(backend) do
    case Code.ensure_loaded(backend) do
      {:module, _} ->
        :ok

      {:error, reason} ->
        Mix.raise("Could not load backend #{inspect(backend)}: #{inspect(reason)}")
    end

    unless function_exported?(backend, :lookup_credential, 1) do
      Mix.raise("#{inspect(backend)} does not implement Firkin.Backend")
    end
  end

  defp maybe_seed_memory_backend(@default_backend, access_key, secret_key) do
    Memory.start()
    Memory.add_credential(access_key, secret_key)
  end

  defp maybe_seed_memory_backend(_other, _access_key, _secret_key), do: :ok

  defp parse_ip!(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} -> ip
      {:error, _} -> Mix.raise("Invalid --bind address: #{str}")
    end
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end

  defp banner(bind, port, backend, access_key, secret_key, hostname) do
    host_display = format_ip(bind)
    url = "http://#{host_display}:#{port}"

    base = """

    Firkin listening on #{url}/
    Backend: #{inspect(backend)}
    """

    vhost_line =
      if hostname, do: "Virtual-hosted-style base: #{hostname}\n", else: ""

    creds_block =
      if backend == @default_backend do
        """

          AWS_ACCESS_KEY_ID=#{access_key} \\
          AWS_SECRET_ACCESS_KEY=#{secret_key} \\
          aws --endpoint-url=#{url} s3 ls
        """
      else
        ""
      end

    base <> vhost_line <> creds_block <> "\nPress Ctrl+C twice to stop.\n"
  end

  defp format_ip({127, 0, 0, 1}), do: "localhost"
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
end
