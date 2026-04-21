defmodule Firkin.Test.TestServer do
  @moduledoc """
  Starts a Bandit HTTP server serving Firkin.Plug for external client testing.
  """

  @spec start(keyword()) :: {:ok, port :: pos_integer()}
  def start(opts \\ []) do
    backend = Keyword.get(opts, :backend, Firkin.Test.MemoryBackend)
    region = Keyword.get(opts, :region, "us-east-1")

    plug_opts = [backend: backend, region: region]

    {:ok, server} =
      Bandit.start_link(
        plug: {Firkin.Plug, plug_opts},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, port}
  end

  @spec ex_aws_config(pos_integer(), String.t(), String.t()) :: keyword()
  def ex_aws_config(port, access_key_id, secret_access_key) do
    [
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      scheme: "http://",
      host: "localhost",
      port: port,
      region: "us-east-1",
      s3: [
        scheme: "http://",
        host: "localhost",
        port: port,
        region: "us-east-1"
      ]
    ]
  end
end
