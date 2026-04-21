defmodule Firkin do
  @moduledoc """
  A Plug-based library for building S3-compatible object storage APIs.

  Firkin handles the S3 HTTP protocol — signature verification, XML response
  formatting, operation routing, multipart upload orchestration — and delegates
  actual storage operations to a user-provided backend module implementing the
  `Firkin.Backend` behaviour.

  ## Quick start

  1. Implement the `Firkin.Backend` behaviour
  2. Mount `Firkin.Plug` in your router

  ```elixir
  forward "/s3", Firkin.Plug, backend: MyApp.S3Backend, region: "us-east-1"
  ```
  """
end
