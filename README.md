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
    {:firkin, "~> 0.2.1"}
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

## Telemetry

Firkin emits a `[:firkin, :request, :start | :stop | :exception]` span for
every request. Attach handlers using module/function captures — not
anonymous functions — ideally from your `Application.start/2`:

```elixir
:telemetry.attach_many(
  "my-firkin-handler",
  [
    [:firkin, :request, :start],
    [:firkin, :request, :stop],
    [:firkin, :request, :exception]
  ],
  &MyApp.FirkinTelemetry.handle_event/4,
  %{}
)
```

Stop metadata includes the S3 `:operation` (e.g. `:put_object`), the
`:bucket`, `:key`, HTTP `:status`, the authenticated `:access_key_id` and
(for error responses) the `:error_code`. See `Firkin.Telemetry` for the
full event contract.

## GitHub Mirror

Eventually, [Forgejo](https://www.forgejo.org) will support fully federated operation, but for now there's a [mirror of this repository on GitHub](https://www.github.com/jimsynz/firkin) - feel free to open issues and PRs there.

## Licence

[Apache-2.0](LICENSE)
