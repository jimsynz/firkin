defmodule Firkin.Telemetry do
  @moduledoc """
  Telemetry events emitted by Firkin.

  Firkin emits a single span per HTTP request routed through `Firkin.Plug`.
  Attach handlers in your application start callback using
  `&Module.function/4` captures — not anonymous functions — so the runtime
  can hot-reload your code.

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

  ## Events

  ### `[:firkin, :request, :start]`

  Emitted when a request enters `Firkin.Plug`.

    * Measurements: `%{monotonic_time, system_time}`
    * Metadata:
      * `:method` — HTTP method (e.g. `"GET"`)
      * `:request_path` — request path as seen by the plug
      * `:request_id` — value placed in the `X-Amz-Request-Id` response header
      * `:telemetry_span_context` — reference correlating start/stop/exception

  ### `[:firkin, :request, :stop]`

  Emitted when the request completes (including handled error responses).

    * Measurements: `%{monotonic_time, duration}` (duration in native units)
    * Metadata: all start metadata plus
      * `:operation` — one of the operation atoms listed below, or `:unknown`
      * `:bucket` — bucket name or `nil` (service-level requests)
      * `:key` — object key or `nil`
      * `:status` — HTTP status code on the response
      * `:access_key_id` — authenticated key id, or `nil` if auth failed
      * `:error_code` — S3 error code atom when the response was an error,
        otherwise `nil`

  ### `[:firkin, :request, :exception]`

  Emitted when an unhandled exception escapes request dispatch. The plug
  still sends a `500 InternalError` response to the client.

    * Measurements: `%{monotonic_time, duration}`
    * Metadata: all start metadata plus the fields described for `:stop`
      (best-effort — `:operation` may be `:unknown` if the exception
      happened before classification) and
      * `:kind` — `:error | :exit | :throw`
      * `:reason` — the raised term
      * `:stacktrace` — the captured stacktrace

  ## Operation atoms

  The `:operation` metadata is one of:

    * `:list_buckets`
    * `:create_bucket`, `:delete_bucket`, `:head_bucket`, `:get_bucket_location`
    * `:list_objects_v2`, `:list_multipart_uploads`
    * `:get_object`, `:head_object`, `:put_object`, `:delete_object`,
      `:delete_objects`, `:copy_object`
    * `:create_multipart_upload`, `:upload_part`,
      `:complete_multipart_upload`, `:abort_multipart_upload`, `:list_parts`
    * `:unknown` — request did not match any recognised S3 operation
  """

  @type operation ::
          :list_buckets
          | :create_bucket
          | :delete_bucket
          | :head_bucket
          | :get_bucket_location
          | :list_objects_v2
          | :list_multipart_uploads
          | :get_object
          | :head_object
          | :put_object
          | :delete_object
          | :delete_objects
          | :copy_object
          | :create_multipart_upload
          | :upload_part
          | :complete_multipart_upload
          | :abort_multipart_upload
          | :list_parts
          | :unknown

  @doc """
  Classifies an S3 request into an operation atom.

  Mirrors the routing in `Firkin.Plug` so the operation can be included in
  telemetry metadata without threading it through every handler.
  """
  @spec classify_operation(
          String.t(),
          bucket :: String.t() | nil,
          key :: String.t() | nil,
          query :: map(),
          req_headers :: [{String.t(), String.t()}]
        ) ::
          operation()
  def classify_operation(method, bucket, key, query, req_headers \\ [])

  def classify_operation("GET", nil, nil, _query, _headers), do: :list_buckets

  def classify_operation("GET", _bucket, nil, %{"location" => _}, _headers),
    do: :get_bucket_location

  def classify_operation("GET", _bucket, nil, %{"uploads" => _}, _headers),
    do: :list_multipart_uploads

  def classify_operation("GET", _bucket, nil, _query, _headers), do: :list_objects_v2

  def classify_operation("PUT", _bucket, nil, _query, _headers), do: :create_bucket
  def classify_operation("DELETE", _bucket, nil, _query, _headers), do: :delete_bucket
  def classify_operation("HEAD", _bucket, nil, _query, _headers), do: :head_bucket

  def classify_operation("POST", _bucket, nil, %{"delete" => _}, _headers),
    do: :delete_objects

  def classify_operation("POST", _bucket, _key, %{"uploads" => _}, _headers),
    do: :create_multipart_upload

  def classify_operation("POST", _bucket, _key, %{"uploadId" => _}, _headers),
    do: :complete_multipart_upload

  def classify_operation(
        "PUT",
        _bucket,
        _key,
        %{"partNumber" => _, "uploadId" => _},
        _headers
      ),
      do: :upload_part

  def classify_operation("DELETE", _bucket, _key, %{"uploadId" => _}, _headers),
    do: :abort_multipart_upload

  def classify_operation("GET", _bucket, _key, %{"uploadId" => _}, _headers),
    do: :list_parts

  def classify_operation("PUT", _bucket, _key, _query, headers) do
    if List.keymember?(headers, "x-amz-copy-source", 0),
      do: :copy_object,
      else: :put_object
  end

  def classify_operation("GET", _bucket, _key, _query, _headers), do: :get_object
  def classify_operation("HEAD", _bucket, _key, _query, _headers), do: :head_object
  def classify_operation("DELETE", _bucket, _key, _query, _headers), do: :delete_object

  def classify_operation(_method, _bucket, _key, _query, _headers), do: :unknown

  @doc false
  @spec start(map()) :: {integer(), map()}
  def start(metadata) do
    start_time = System.monotonic_time()

    measurements = %{
      monotonic_time: start_time,
      system_time: System.system_time()
    }

    metadata = Map.put_new(metadata, :telemetry_span_context, make_ref())
    :telemetry.execute([:firkin, :request, :start], measurements, metadata)
    {start_time, metadata}
  end

  @doc false
  @spec stop(integer(), map()) :: :ok
  def stop(start_time, metadata) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:firkin, :request, :stop],
      %{monotonic_time: now, duration: now - start_time},
      metadata
    )
  end

  @doc false
  @spec exception(integer(), map()) :: :ok
  def exception(start_time, metadata) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:firkin, :request, :exception],
      %{monotonic_time: now, duration: now - start_time},
      metadata
    )
  end
end
