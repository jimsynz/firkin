defmodule Firkin.Plug do
  @moduledoc """
  Plug that serves an S3-compatible HTTP API.

  Mount this plug in your router and provide a backend module:

      forward "/s3", Firkin.Plug, backend: MyApp.S3Backend, region: "us-east-1"

  ## Options

    * `:backend` (required) — module implementing `Firkin.Backend`
    * `:region` — AWS region string for SigV4 scope and GetBucketLocation
      (default: `"us-east-1"`)
    * `:hostname` — base hostname for virtual-hosted-style requests.
      When set, requests with `Host: bucket.hostname` extract the bucket
      from the hostname instead of the path. Path-style requests continue
      to work regardless.
      (default: `nil` — virtual-hosted-style disabled)
    * `:request_id_prefix` — prefix for X-Amz-Request-Id header
      (default: `"firkin"`)
    * `:max_buffered_put_bytes` — cap (in bytes) on PUT/UploadPart bodies
      when the backend has opted into the buffered `put_object/5` /
      `upload_part/6` path. Bodies exceeding the cap return
      `413 Request Entity Too Large` instead of silently allocating
      gigabytes of iodata. Ignored when the backend implements
      `put_object_stream/5` / `upload_part_stream/6`. Default:
      `#{div(16 * 1024 * 1024, 1024)} KiB`.
  """

  @default_max_buffered_put_bytes 16 * 1024 * 1024
  @body_chunk_size 64 * 1024

  @behaviour Plug

  require Logger

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      backend: Keyword.fetch!(opts, :backend),
      region: Keyword.get(opts, :region, "us-east-1"),
      hostname: Keyword.get(opts, :hostname),
      request_id_prefix: Keyword.get(opts, :request_id_prefix, "firkin"),
      max_buffered_put_bytes:
        Keyword.get(opts, :max_buffered_put_bytes, @default_max_buffered_put_bytes)
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    request_id = generate_request_id(opts.request_id_prefix)

    conn
    |> Plug.Conn.put_resp_header("x-amz-request-id", request_id)
    |> Plug.Conn.put_resp_header("server", "Firkin")
    |> authenticate_and_dispatch(opts, request_id)
  end

  defp authenticate_and_dispatch(conn, opts, request_id) do
    case Firkin.Auth.authenticate(conn, opts.backend) do
      {:ok, auth_context} ->
        dispatch(conn, opts, auth_context, request_id)

      {:error, :credential_not_found} ->
        send_error(conn, %Firkin.Error{code: :access_denied, request_id: request_id})

      {:error, :invalid_signature} ->
        send_error(conn, %Firkin.Error{
          code: :signature_does_not_match,
          request_id: request_id
        })

      {:error, :expired} ->
        send_error(conn, %Firkin.Error{code: :access_denied, request_id: request_id})
    end
  end

  defp dispatch(conn, opts, auth_context, request_id) do
    {bucket, key} = extract_bucket_key(conn, opts.hostname)
    query = URI.decode_query(conn.query_string)

    route(conn, conn.method, bucket, key, query, opts, auth_context, request_id)
  rescue
    e ->
      Logger.error("Firkin dispatch error: #{Exception.message(e)}")

      send_error(conn, %Firkin.Error{code: :internal_error, request_id: request_id})
  end

  # Service-level: GET / → ListBuckets
  defp route(conn, "GET", nil, nil, _query, opts, ctx, req_id) do
    handle_list_buckets(conn, opts.backend, ctx, req_id)
  end

  # Bucket-level operations with query parameter dispatch
  defp route(conn, "GET", bucket, nil, %{"location" => _}, opts, ctx, req_id) do
    handle_get_bucket_location(conn, opts, bucket, ctx, req_id)
  end

  defp route(conn, "GET", bucket, nil, %{"uploads" => _}, opts, ctx, req_id) do
    handle_list_multipart_uploads(conn, opts.backend, bucket, ctx, req_id)
  end

  defp route(conn, "GET", bucket, nil, query, opts, ctx, req_id) do
    handle_list_objects_v2(conn, opts.backend, bucket, query, ctx, req_id)
  end

  defp route(conn, "PUT", bucket, nil, _query, opts, ctx, req_id) do
    handle_create_bucket(conn, opts.backend, bucket, ctx, req_id)
  end

  defp route(conn, "DELETE", bucket, nil, _query, opts, ctx, req_id) do
    handle_delete_bucket(conn, opts.backend, bucket, ctx, req_id)
  end

  defp route(conn, "HEAD", bucket, nil, _query, opts, ctx, req_id) do
    handle_head_bucket(conn, opts.backend, bucket, ctx, req_id)
  end

  defp route(conn, "POST", bucket, nil, %{"delete" => _}, opts, ctx, req_id) do
    handle_delete_objects(conn, opts.backend, bucket, ctx, req_id)
  end

  # Object-level operations with query parameter dispatch
  defp route(conn, "POST", bucket, key, %{"uploads" => _}, opts, ctx, req_id) do
    handle_create_multipart_upload(conn, opts.backend, bucket, key, ctx, req_id)
  end

  defp route(conn, "POST", bucket, key, %{"uploadId" => upload_id}, opts, ctx, req_id) do
    handle_complete_multipart_upload(conn, opts.backend, bucket, key, upload_id, ctx, req_id)
  end

  defp route(
         conn,
         "PUT",
         bucket,
         key,
         %{"partNumber" => part_num, "uploadId" => upload_id},
         opts,
         ctx,
         req_id
       ) do
    handle_upload_part(conn, opts, bucket, key, upload_id, part_num, ctx, req_id)
  end

  defp route(conn, "DELETE", bucket, key, %{"uploadId" => upload_id}, opts, ctx, req_id) do
    handle_abort_multipart_upload(conn, opts.backend, bucket, key, upload_id, ctx, req_id)
  end

  defp route(conn, "GET", bucket, key, %{"uploadId" => upload_id}, opts, ctx, req_id) do
    handle_list_parts(conn, opts.backend, bucket, key, upload_id, ctx, req_id)
  end

  # CopyObject: PUT with x-amz-copy-source header
  defp route(conn, "PUT", bucket, key, _query, opts, ctx, req_id) do
    case Plug.Conn.get_req_header(conn, "x-amz-copy-source") do
      [copy_source | _] ->
        handle_copy_object(conn, opts.backend, bucket, key, copy_source, ctx, req_id)

      [] ->
        handle_put_object(conn, opts, bucket, key, ctx, req_id)
    end
  end

  defp route(conn, "GET", bucket, key, _query, opts, ctx, req_id) do
    handle_get_object(conn, opts.backend, bucket, key, ctx, req_id)
  end

  defp route(conn, "HEAD", bucket, key, _query, opts, ctx, req_id) do
    handle_head_object(conn, opts.backend, bucket, key, ctx, req_id)
  end

  defp route(conn, "DELETE", bucket, key, _query, opts, ctx, req_id) do
    handle_delete_object(conn, opts.backend, bucket, key, ctx, req_id)
  end

  defp route(conn, _method, _bucket, _key, _query, _opts, _ctx, req_id) do
    send_error(conn, %Firkin.Error{code: :not_implemented, request_id: req_id})
  end

  defp handle_list_buckets(conn, backend, ctx, req_id) do
    case backend.list_buckets(ctx) do
      {:ok, buckets} ->
        send_xml(conn, 200, Firkin.XML.list_buckets_response(buckets))

      {:error, error} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_create_bucket(conn, backend, bucket, ctx, req_id) do
    case backend.create_bucket(ctx, bucket) do
      :ok ->
        conn
        |> Plug.Conn.put_resp_header("location", "/#{bucket}")
        |> Plug.Conn.send_resp(200, "")

      {:error, error} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_delete_bucket(conn, backend, bucket, ctx, req_id) do
    case backend.delete_bucket(ctx, bucket) do
      :ok -> Plug.Conn.send_resp(conn, 204, "")
      {:error, error} -> send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_head_bucket(conn, backend, bucket, ctx, req_id) do
    case backend.head_bucket(ctx, bucket) do
      :ok -> Plug.Conn.send_resp(conn, 200, "")
      {:error, error} -> send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_get_bucket_location(conn, opts, bucket, ctx, req_id) do
    case opts.backend.get_bucket_location(ctx, bucket) do
      {:ok, location} ->
        send_xml(conn, 200, Firkin.XML.get_bucket_location_response(location))

      {:error, error} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_list_objects_v2(conn, backend, bucket, query, ctx, req_id) do
    list_opts = %Firkin.ListOpts{
      prefix: Map.get(query, "prefix"),
      delimiter: Map.get(query, "delimiter"),
      max_keys: parse_int(Map.get(query, "max-keys"), 1000),
      continuation_token: Map.get(query, "continuation-token"),
      start_after: Map.get(query, "start-after"),
      fetch_owner: Map.get(query, "fetch-owner") == "true"
    }

    case backend.list_objects_v2(ctx, bucket, list_opts) do
      {:ok, result} ->
        send_xml(conn, 200, Firkin.XML.list_objects_v2_response(result))

      {:error, error} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_put_object(conn, opts, bucket, key, ctx, req_id) do
    put_opts = %Firkin.PutOpts{
      content_type: get_content_type(conn),
      metadata: extract_user_metadata(conn)
    }

    {result, conn} =
      if function_exported?(opts.backend, :put_object_stream, 5) do
        stream_put_object(conn, opts.backend, ctx, bucket, key, put_opts)
      else
        buffered_put_object(conn, opts, ctx, bucket, key, put_opts)
      end

    case result do
      {:ok, etag} ->
        conn
        |> Plug.Conn.put_resp_header("etag", ensure_quoted(etag))
        |> Plug.Conn.send_resp(200, "")

      {:error, error} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp stream_put_object(conn, backend, ctx, bucket, key, put_opts) do
    {body_stream, finish} = build_body_stream(conn)

    result = backend.put_object_stream(ctx, bucket, key, body_stream, put_opts)
    {result, finish.()}
  end

  defp buffered_put_object(conn, opts, ctx, bucket, key, put_opts) do
    case read_capped_body(conn, opts.max_buffered_put_bytes) do
      {:ok, body, conn} ->
        {opts.backend.put_object(ctx, bucket, key, body, put_opts), conn}

      {:too_large, conn} ->
        {{:error, too_large_error(opts.max_buffered_put_bytes)}, conn}
    end
  end

  defp handle_get_object(conn, backend, bucket, key, ctx, req_id) do
    get_opts = %Firkin.GetOpts{
      range: parse_range(conn),
      if_match: get_header(conn, "if-match"),
      if_none_match: get_header(conn, "if-none-match"),
      if_modified_since: parse_http_date(get_header(conn, "if-modified-since")),
      if_unmodified_since: parse_http_date(get_header(conn, "if-unmodified-since"))
    }

    with {:ok, object} <- backend.get_object(ctx, bucket, key, get_opts),
         :ok <- check_preconditions(get_opts, object.etag, object.last_modified) do
      status = if get_opts.range, do: 206, else: 200

      conn
      |> Plug.Conn.put_resp_header("accept-ranges", "bytes")
      |> Plug.Conn.put_resp_header("etag", ensure_quoted(object.etag))
      |> Plug.Conn.put_resp_header("content-type", object.content_type)
      |> Plug.Conn.put_resp_header("content-length", to_string(object.content_length))
      |> Plug.Conn.put_resp_header("last-modified", format_http_date(object.last_modified))
      |> maybe_put_content_range(get_opts.range, object)
      |> put_user_metadata(object.metadata)
      |> send_body(status, object.body)
    else
      {:error, %Firkin.Error{} = error} ->
        send_error(conn, %{error | request_id: req_id})

      {:error, code} when is_atom(code) ->
        send_error(conn, %Firkin.Error{code: code, request_id: req_id})
    end
  end

  defp handle_head_object(conn, backend, bucket, key, ctx, req_id) do
    head_opts = %Firkin.GetOpts{
      if_match: get_header(conn, "if-match"),
      if_none_match: get_header(conn, "if-none-match"),
      if_modified_since: parse_http_date(get_header(conn, "if-modified-since")),
      if_unmodified_since: parse_http_date(get_header(conn, "if-unmodified-since"))
    }

    with {:ok, meta} <- backend.head_object(ctx, bucket, key),
         :ok <- check_preconditions(head_opts, meta.etag, meta.last_modified) do
      conn
      |> Plug.Conn.put_resp_header("etag", ensure_quoted(meta.etag))
      |> Plug.Conn.put_resp_header("content-type", meta.content_type)
      |> Plug.Conn.put_resp_header("content-length", to_string(meta.size))
      |> Plug.Conn.put_resp_header("last-modified", format_http_date(meta.last_modified))
      |> put_user_metadata(meta.metadata)
      |> Plug.Conn.send_resp(200, "")
    else
      {:error, %Firkin.Error{} = error} ->
        send_error(conn, %{error | request_id: req_id})

      {:error, code} when is_atom(code) ->
        send_error(conn, %Firkin.Error{code: code, request_id: req_id})
    end
  end

  defp handle_delete_object(conn, backend, bucket, key, ctx, req_id) do
    case backend.delete_object(ctx, bucket, key) do
      :ok -> Plug.Conn.send_resp(conn, 204, "")
      {:error, error} -> send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_delete_objects(conn, backend, bucket, ctx, req_id) do
    {:ok, body, conn} = read_full_body(conn)

    case Firkin.XML.parse_delete_objects(body) do
      {:ok, keys} ->
        case backend.delete_objects(ctx, bucket, keys) do
          {:ok, result} ->
            send_xml(conn, 200, Firkin.XML.delete_objects_response(result))

          {:error, error} ->
            send_error(conn, %{error | request_id: req_id})
        end

      {:error, :invalid_xml} ->
        send_error(conn, %Firkin.Error{code: :invalid_argument, request_id: req_id})
    end
  end

  defp handle_copy_object(conn, backend, bucket, key, copy_source, ctx, req_id) do
    {source_bucket, source_key} = parse_copy_source(copy_source)

    case backend.copy_object(ctx, bucket, key, source_bucket, source_key) do
      {:ok, result} ->
        send_xml(conn, 200, Firkin.XML.copy_object_response(result))

      {:error, error} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_create_multipart_upload(conn, backend, bucket, key, ctx, req_id) do
    if function_exported?(backend, :create_multipart_upload, 4) do
      opts = %{content_type: get_content_type(conn), metadata: extract_user_metadata(conn)}

      case backend.create_multipart_upload(ctx, bucket, key, opts) do
        {:ok, upload_id} ->
          send_xml(
            conn,
            200,
            Firkin.XML.initiate_multipart_upload_response(bucket, key, upload_id)
          )

        {:error, error} ->
          send_error(conn, %{error | request_id: req_id})
      end
    else
      send_error(conn, %Firkin.Error{code: :not_implemented, request_id: req_id})
    end
  end

  defp handle_upload_part(conn, opts, bucket, key, upload_id, part_num_str, ctx, req_id) do
    cond do
      function_exported?(opts.backend, :upload_part_stream, 6) ->
        part_number = String.to_integer(part_num_str)

        dispatch_upload_part(
          conn,
          req_id,
          fn conn ->
            stream_upload_part(conn, opts.backend, ctx, bucket, key, upload_id, part_number)
          end
        )

      function_exported?(opts.backend, :upload_part, 6) ->
        part_number = String.to_integer(part_num_str)

        dispatch_upload_part(
          conn,
          req_id,
          fn conn ->
            buffered_upload_part(conn, opts, ctx, bucket, key, upload_id, part_number)
          end
        )

      true ->
        send_error(conn, %Firkin.Error{code: :not_implemented, request_id: req_id})
    end
  end

  defp dispatch_upload_part(conn, req_id, fun) do
    case fun.(conn) do
      {{:ok, etag}, conn} ->
        conn
        |> Plug.Conn.put_resp_header("etag", ensure_quoted(etag))
        |> Plug.Conn.send_resp(200, "")

      {{:error, error}, conn} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp stream_upload_part(conn, backend, ctx, bucket, key, upload_id, part_number) do
    {body_stream, finish} = build_body_stream(conn)
    result = backend.upload_part_stream(ctx, bucket, key, upload_id, part_number, body_stream)
    {result, finish.()}
  end

  defp buffered_upload_part(conn, opts, ctx, bucket, key, upload_id, part_number) do
    case read_capped_body(conn, opts.max_buffered_put_bytes) do
      {:ok, body, conn} ->
        {opts.backend.upload_part(ctx, bucket, key, upload_id, part_number, body), conn}

      {:too_large, conn} ->
        {{:error, too_large_error(opts.max_buffered_put_bytes)}, conn}
    end
  end

  defp handle_complete_multipart_upload(conn, backend, bucket, key, upload_id, ctx, req_id) do
    if function_exported?(backend, :complete_multipart_upload, 5) do
      {:ok, body, conn} = read_full_body(conn)
      do_complete_multipart(conn, backend, bucket, key, upload_id, body, ctx, req_id)
    else
      send_error(conn, %Firkin.Error{code: :not_implemented, request_id: req_id})
    end
  end

  defp do_complete_multipart(conn, backend, bucket, key, upload_id, body, ctx, req_id) do
    with {:ok, parts} <- Firkin.XML.parse_complete_multipart(body),
         {:ok, result} <- backend.complete_multipart_upload(ctx, bucket, key, upload_id, parts) do
      send_xml(conn, 200, Firkin.XML.complete_multipart_upload_response(result))
    else
      {:error, :invalid_xml} ->
        send_error(conn, %Firkin.Error{code: :invalid_argument, request_id: req_id})

      {:error, error} ->
        send_error(conn, %{error | request_id: req_id})
    end
  end

  defp handle_abort_multipart_upload(conn, backend, bucket, key, upload_id, ctx, req_id) do
    if function_exported?(backend, :abort_multipart_upload, 4) do
      case backend.abort_multipart_upload(ctx, bucket, key, upload_id) do
        :ok -> Plug.Conn.send_resp(conn, 204, "")
        {:error, error} -> send_error(conn, %{error | request_id: req_id})
      end
    else
      send_error(conn, %Firkin.Error{code: :not_implemented, request_id: req_id})
    end
  end

  defp handle_list_multipart_uploads(conn, backend, bucket, ctx, req_id) do
    if function_exported?(backend, :list_multipart_uploads, 3) do
      case backend.list_multipart_uploads(ctx, bucket, %{}) do
        {:ok, result} ->
          send_xml(conn, 200, Firkin.XML.list_multipart_uploads_response(result))

        {:error, error} ->
          send_error(conn, %{error | request_id: req_id})
      end
    else
      send_error(conn, %Firkin.Error{code: :not_implemented, request_id: req_id})
    end
  end

  defp handle_list_parts(conn, backend, bucket, key, upload_id, ctx, req_id) do
    if function_exported?(backend, :list_parts, 5) do
      case backend.list_parts(ctx, bucket, key, upload_id, %{}) do
        {:ok, result} ->
          send_xml(conn, 200, Firkin.XML.list_parts_response(result))

        {:error, error} ->
          send_error(conn, %{error | request_id: req_id})
      end
    else
      send_error(conn, %Firkin.Error{code: :not_implemented, request_id: req_id})
    end
  end

  defp send_body(conn, status, body) when is_binary(body) or is_list(body) do
    Plug.Conn.send_resp(conn, status, body)
  end

  defp send_body(conn, status, stream) do
    conn = Plug.Conn.send_chunked(conn, status)

    Enum.reduce_while(stream, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp send_xml(conn, status, xml) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(status, xml)
  end

  defp send_error(conn, %Firkin.Error{code: :not_modified}) do
    Plug.Conn.send_resp(conn, 304, "")
  end

  defp send_error(conn, %Firkin.Error{} = error) do
    status = Firkin.Error.to_http_status(error.code)
    xml = Firkin.XML.error_response(error)

    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(status, xml)
  end

  defp extract_bucket_key(conn, hostname) do
    case extract_virtual_hosted_bucket(conn, hostname) do
      {:ok, bucket} -> extract_key_from_path(bucket, conn.path_info)
      :path_style -> extract_bucket_key_from_path(conn.path_info)
    end
  end

  defp extract_virtual_hosted_bucket(conn, hostname) when is_binary(hostname) do
    case Plug.Conn.get_req_header(conn, "host") do
      [host | _] ->
        bare_host = strip_port(host)
        suffix = "." <> hostname

        if String.ends_with?(bare_host, suffix) and bare_host != hostname do
          bucket = String.slice(bare_host, 0, byte_size(bare_host) - byte_size(suffix))
          {:ok, bucket}
        else
          :path_style
        end

      [] ->
        :path_style
    end
  end

  defp extract_virtual_hosted_bucket(_conn, _hostname), do: :path_style

  defp strip_port(host) do
    case String.split(host, ":", parts: 2) do
      [bare, _port] -> bare
      [bare] -> bare
    end
  end

  defp extract_key_from_path(bucket, []) do
    {bucket, nil}
  end

  defp extract_key_from_path(bucket, key_parts) do
    {bucket, Enum.join(key_parts, "/")}
  end

  defp extract_bucket_key_from_path([]) do
    {nil, nil}
  end

  defp extract_bucket_key_from_path([bucket]) do
    {bucket, nil}
  end

  defp extract_bucket_key_from_path([bucket | key_parts]) do
    {bucket, Enum.join(key_parts, "/")}
  end

  defp parse_copy_source(source) do
    source = String.trim_leading(source, "/")

    case String.split(source, "/", parts: 2) do
      [bucket, key] -> {bucket, key}
      [bucket] -> {bucket, ""}
    end
  end

  defp read_full_body(conn, acc \\ []) do
    # PUT/UploadPart bodies go through build_body_stream/1 (streaming) or
    # read_capped_body/2 (capped buffered fallback); this helper is used
    # only for small XML bodies (DeleteObjects, CompleteMultipartUpload).
    # audit:bounded XML-only helper — S3 DeleteObjects/CompleteMultipart are kilobytes at most
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, IO.iodata_to_binary([acc, body]), conn}
      {:more, partial, conn} -> read_full_body(conn, [acc, partial])
      {:error, reason} -> {:error, reason}
    end
  end

  # Builds a lazy `Stream` over the request body without buffering the
  # full payload. Returns `{stream, finish_fn}`. Callers must invoke
  # `finish_fn.()` after the backend finishes consuming the stream to
  # retrieve the up-to-date `Plug.Conn` (Stream.resource discards its
  # accumulator so we stash the evolving conn in the process dictionary
  # — safe because each request runs in a dedicated plug pipeline
  # process).
  defp build_body_stream(conn) do
    key = {__MODULE__, make_ref()}
    Process.put(key, conn)

    stream =
      Stream.resource(
        fn -> :continue end,
        fn
          :done ->
            {:halt, :done}

          :continue ->
            conn = Process.get(key)

            case Plug.Conn.read_body(conn, length: @body_chunk_size) do
              {:ok, "", new_conn} ->
                Process.put(key, new_conn)
                {:halt, :done}

              {:ok, chunk, new_conn} ->
                Process.put(key, new_conn)
                {[chunk], :done}

              {:more, chunk, new_conn} ->
                Process.put(key, new_conn)
                {[chunk], :continue}
            end
        end,
        fn _ -> :ok end
      )

    finish = fn ->
      final_conn = Process.get(key, conn)
      Process.delete(key)
      final_conn
    end

    {stream, finish}
  end

  # Reads up to `cap` bytes from the request body. Returns `:too_large`
  # when the peer is still sending after the cap so the caller can
  # respond 413.
  defp read_capped_body(conn, cap) do
    case Plug.Conn.read_body(conn, length: cap, read_length: @body_chunk_size) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:too_large, drain_body(conn)}
    end
  end

  defp drain_body(conn) do
    case Plug.Conn.read_body(conn, length: @body_chunk_size, read_length: @body_chunk_size) do
      {:ok, _final, conn} -> conn
      {:more, _partial, conn} -> drain_body(conn)
    end
  end

  defp too_large_error(cap) do
    %Firkin.Error{
      code: :entity_too_large,
      message:
        "Body exceeds buffered PUT cap (#{cap} bytes). Implement " <>
          "put_object_stream/5 or upload_part_stream/6 on the backend, " <>
          "or raise :max_buffered_put_bytes."
    }
  end

  defp get_content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [ct | _] -> ct
      [] -> "application/octet-stream"
    end
  end

  defp extract_user_metadata(conn) do
    conn.req_headers
    |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-amz-meta-") end)
    |> Map.new(fn {k, v} -> {String.replace_leading(k, "x-amz-meta-", ""), v} end)
  end

  defp maybe_put_content_range(conn, nil, _object), do: conn

  defp maybe_put_content_range(conn, {start_byte, _end_byte}, object) do
    actual_end = start_byte + object.content_length - 1
    total = object.total_size || "*"
    Plug.Conn.put_resp_header(conn, "content-range", "bytes #{start_byte}-#{actual_end}/#{total}")
  end

  defp put_user_metadata(conn, metadata) do
    Enum.reduce(metadata, conn, fn {k, v}, acc ->
      Plug.Conn.put_resp_header(acc, "x-amz-meta-#{k}", v)
    end)
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp parse_range(conn) do
    case get_header(conn, "range") do
      "bytes=" <> range_str -> parse_byte_range(range_str)
      _ -> nil
    end
  end

  defp parse_byte_range(range_str) do
    with [start_str, end_str] <- String.split(range_str, "-", parts: 2),
         {start_byte, ""} <- Integer.parse(start_str),
         {end_byte, ""} <- Integer.parse(end_str) do
      {start_byte, end_byte}
    else
      _ -> nil
    end
  end

  # Evaluates conditional request headers per RFC 7232 §6.
  # Order: If-Match → If-Unmodified-Since → If-None-Match → If-Modified-Since
  @spec check_preconditions(Firkin.GetOpts.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :precondition_failed | :not_modified}
  defp check_preconditions(opts, etag, last_modified) do
    quoted_etag = ensure_quoted(etag)

    with :ok <- check_if_match(opts.if_match, quoted_etag),
         :ok <- check_if_unmodified_since(opts.if_unmodified_since, last_modified, opts.if_match),
         :ok <- check_if_none_match(opts.if_none_match, quoted_etag) do
      check_if_modified_since(opts.if_modified_since, last_modified, opts.if_none_match)
    end
  end

  defp check_if_match(nil, _etag), do: :ok

  defp check_if_match(if_match, etag) do
    if etag_matches?(if_match, etag), do: :ok, else: {:error, :precondition_failed}
  end

  # If-Match is present, If-Unmodified-Since is ignored (RFC 7232 §3.4)
  defp check_if_unmodified_since(_date, _last_modified, if_match) when not is_nil(if_match),
    do: :ok

  defp check_if_unmodified_since(nil, _last_modified, _if_match), do: :ok

  defp check_if_unmodified_since(date, last_modified, _if_match) do
    if DateTime.compare(last_modified, date) == :gt,
      do: {:error, :precondition_failed},
      else: :ok
  end

  defp check_if_none_match(nil, _etag), do: :ok

  defp check_if_none_match(if_none_match, etag) do
    if etag_matches?(if_none_match, etag), do: {:error, :not_modified}, else: :ok
  end

  # If-None-Match is present, If-Modified-Since is ignored (RFC 7232 §3.3)
  defp check_if_modified_since(_date, _last_modified, if_none_match)
       when not is_nil(if_none_match),
       do: :ok

  defp check_if_modified_since(nil, _last_modified, _if_none_match), do: :ok

  defp check_if_modified_since(date, last_modified, _if_none_match) do
    if DateTime.compare(last_modified, date) == :gt, do: :ok, else: {:error, :not_modified}
  end

  defp etag_matches?("*", _etag), do: true

  defp etag_matches?(header_value, etag) do
    header_value
    |> String.split(",")
    |> Enum.any?(fn candidate -> String.trim(candidate) == etag end)
  end

  defp parse_http_date(nil), do: nil

  defp parse_http_date(date_str) do
    case :httpd_util.convert_request_date(String.to_charlist(date_str)) do
      :bad_date ->
        nil

      {date, time} ->
        with {:ok, naive} <- NaiveDateTime.from_erl({date, time}),
             {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
          dt
        else
          _ -> nil
        end
    end
  end

  defp format_http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp ensure_quoted(etag) do
    if String.starts_with?(etag, "\""), do: etag, else: "\"#{etag}\""
  end

  defp generate_request_id(prefix) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :upper)
    "#{prefix}-#{random}"
  end
end
