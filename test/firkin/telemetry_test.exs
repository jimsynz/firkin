defmodule Firkin.TelemetryTest do
  use ExUnit.Case, async: false

  alias Firkin.Backends.Memory, as: MemoryBackend
  alias Firkin.Test.SigV4Helper

  @access_key "TELEMETRYKEY"
  @secret_key "TELEMETRYSECRET"

  @events [
    [:firkin, :request, :start],
    [:firkin, :request, :stop],
    [:firkin, :request, :exception]
  ]

  setup do
    MemoryBackend.start()
    MemoryBackend.add_credential(@access_key, @secret_key)

    test_pid = self()
    handler_id = {:telemetry_test, make_ref()}

    :telemetry.attach_many(
      handler_id,
      @events,
      &__MODULE__.forward_event/4,
      %{pid: test_pid}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    opts = Firkin.Plug.init(backend: MemoryBackend, region: "us-east-1")
    {:ok, opts: opts}
  end

  def forward_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp signed_conn(method, path, opts \\ []) do
    body = Keyword.get(opts, :body, "")
    headers = Keyword.get(opts, :headers, [])

    conn =
      Plug.Test.conn(method, path, body)
      |> Map.put(:req_headers, [{"host", "localhost"} | headers])

    SigV4Helper.sign_conn(conn, @access_key, @secret_key, body: body)
  end

  defp call(conn, opts), do: Firkin.Plug.call(conn, opts)

  defp assert_start_stop(expected_operation) do
    assert_receive {:telemetry_event, [:firkin, :request, :start], start_meas, start_meta}
    assert_receive {:telemetry_event, [:firkin, :request, :stop], stop_meas, stop_meta}

    assert is_integer(start_meas.monotonic_time)
    assert is_integer(start_meas.system_time)
    assert is_integer(stop_meas.monotonic_time)
    assert is_integer(stop_meas.duration)
    assert stop_meas.duration >= 0

    assert start_meta.operation == expected_operation
    assert stop_meta.operation == expected_operation
    assert start_meta.telemetry_span_context == stop_meta.telemetry_span_context
    assert is_reference(stop_meta.telemetry_span_context)

    {start_meta, stop_meta}
  end

  describe "request span" do
    test "emits start/stop for ListBuckets", %{opts: opts} do
      conn = signed_conn(:get, "/") |> call(opts)
      assert conn.status == 200

      {start_meta, stop_meta} = assert_start_stop(:list_buckets)

      assert start_meta.method == "GET"
      assert start_meta.request_path == "/"
      assert String.starts_with?(start_meta.request_id, "firkin-")
      assert start_meta.bucket == nil
      assert start_meta.key == nil

      assert stop_meta.status == 200
      assert stop_meta.access_key_id == @access_key
      assert stop_meta.error_code == nil
    end

    test "emits start/stop for CreateBucket", %{opts: opts} do
      conn = signed_conn(:put, "/tele-bucket") |> call(opts)
      assert conn.status == 200

      {start_meta, stop_meta} = assert_start_stop(:create_bucket)

      assert start_meta.bucket == "tele-bucket"
      assert start_meta.key == nil
      assert stop_meta.status == 200
      assert stop_meta.access_key_id == @access_key
    end

    test "emits start/stop for PutObject with bucket and key", %{opts: opts} do
      signed_conn(:put, "/obj-bucket") |> call(opts)

      conn =
        signed_conn(:put, "/obj-bucket/hello.txt",
          body: "hi",
          headers: [{"content-type", "text/plain"}]
        )
        |> call(opts)

      assert conn.status == 200

      assert_receive {:telemetry_event, [:firkin, :request, :start], _,
                      %{operation: :create_bucket}}

      assert_receive {:telemetry_event, [:firkin, :request, :stop], _,
                      %{operation: :create_bucket}}

      assert_receive {:telemetry_event, [:firkin, :request, :start], _, start_meta}
      assert start_meta.operation == :put_object
      assert start_meta.bucket == "obj-bucket"
      assert start_meta.key == "hello.txt"

      assert_receive {:telemetry_event, [:firkin, :request, :stop], _, stop_meta}
      assert stop_meta.operation == :put_object
      assert stop_meta.status == 200
      assert stop_meta.error_code == nil
    end

    test "classifies CopyObject via x-amz-copy-source", %{opts: opts} do
      signed_conn(:put, "/copy-src") |> call(opts)

      signed_conn(:put, "/copy-src/file",
        body: "payload",
        headers: [{"content-type", "text/plain"}]
      )
      |> call(opts)

      signed_conn(:put, "/copy-dst") |> call(opts)

      flush_events()

      signed_conn(:put, "/copy-dst/file", headers: [{"x-amz-copy-source", "/copy-src/file"}])
      |> call(opts)

      assert_receive {:telemetry_event, [:firkin, :request, :start], _,
                      %{operation: :copy_object}}

      assert_receive {:telemetry_event, [:firkin, :request, :stop], _, stop_meta}
      assert stop_meta.operation == :copy_object
      assert stop_meta.status == 200
    end
  end

  describe "error metadata" do
    test "includes error_code for bucket not found", %{opts: opts} do
      conn = signed_conn(:head, "/missing-bucket") |> call(opts)
      assert conn.status == 404

      {_start_meta, stop_meta} = assert_start_stop(:head_bucket)

      assert stop_meta.status == 404
      assert stop_meta.error_code == :no_such_bucket
    end

    test "reports access_denied on missing credential", %{opts: opts} do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:req_headers, [{"host", "localhost"}])
        |> SigV4Helper.sign_conn("UNKNOWN_KEY", "UNKNOWN_SECRET", body: "")
        |> call(opts)

      assert conn.status == 403

      {_start_meta, stop_meta} = assert_start_stop(:list_buckets)

      assert stop_meta.access_key_id == nil
      assert stop_meta.error_code == :access_denied
    end
  end

  describe "exception path" do
    defmodule CrashingBackend do
      @behaviour Firkin.Backend

      @impl true
      def lookup_credential(_),
        do:
          {:ok,
           %Firkin.Credential{
             access_key_id: "TELEMETRYKEY",
             secret_access_key: "TELEMETRYSECRET",
             identity: :crash
           }}

      @impl true
      def list_buckets(_ctx), do: raise("boom")

      @impl true
      def create_bucket(_, _), do: :ok
      @impl true
      def delete_bucket(_, _), do: :ok
      @impl true
      def head_bucket(_, _), do: :ok
      @impl true
      def get_bucket_location(_, _), do: {:ok, "us-east-1"}
      @impl true
      def get_object(_, _, _, _), do: {:error, %Firkin.Error{code: :no_such_key}}
      @impl true
      def put_object(_, _, _, _, _), do: {:ok, "etag"}
      @impl true
      def delete_object(_, _, _), do: :ok
      @impl true
      def delete_objects(_, _, _), do: {:error, %Firkin.Error{code: :internal_error}}
      @impl true
      def head_object(_, _, _), do: {:error, %Firkin.Error{code: :no_such_key}}
      @impl true
      def list_objects_v2(_, _, _), do: {:error, %Firkin.Error{code: :internal_error}}
      @impl true
      def copy_object(_, _, _, _, _), do: {:error, %Firkin.Error{code: :no_such_key}}
    end

    test "emits exception event when a handler raises" do
      opts = Firkin.Plug.init(backend: CrashingBackend)

      conn = signed_conn(:get, "/") |> call(opts)
      assert conn.status == 500

      assert_receive {:telemetry_event, [:firkin, :request, :start], _, start_meta}
      assert start_meta.operation == :list_buckets

      assert_receive {:telemetry_event, [:firkin, :request, :exception], meas, meta}
      assert is_integer(meas.duration)
      assert meta.operation == :list_buckets
      assert meta.status == 500
      assert meta.error_code == :internal_error
      assert meta.kind == :error
      assert %RuntimeError{message: "boom"} = meta.reason
      assert is_list(meta.stacktrace)

      refute_receive {:telemetry_event, [:firkin, :request, :stop], _, _}
    end
  end

  defp flush_events do
    receive do
      {:telemetry_event, _, _, _} -> flush_events()
    after
      0 -> :ok
    end
  end
end
