# Firkin

A Plug-based library for building S3-compatible object storage APIs in Elixir.

Firkin handles the S3 HTTP protocol — signature verification, XML response
formatting, operation routing, multipart upload orchestration — and delegates
actual storage operations to a user-provided backend module implementing the
`Firkin.Backend` behaviour.

## Installation

Add `firkin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:firkin, "~> 0.1.0"}
  ]
end
```

Documentation is published on [HexDocs](https://hexdocs.pm/firkin).

## Usage

Define a backend module implementing `Firkin.Backend`:

```elixir
defmodule MyApp.S3Backend do
  @behaviour Firkin.Backend

  @impl true
  def lookup_credential(access_key_id) do
    # Return {:ok, %Firkin.Credential{}} or {:error, :not_found}
  end

  @impl true
  def list_buckets(_context) do
    {:ok, [%Firkin.Bucket{name: "my-bucket", creation_date: ~U[2024-01-01 00:00:00Z]}]}
  end

  # ... implement remaining callbacks
end
```

Mount the plug in your router:

```elixir
forward "/s3", Firkin.Plug, backend: MyApp.S3Backend, region: "us-east-1"
```

## Licence

[Apache-2.0](LICENSE)
