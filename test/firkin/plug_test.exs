defmodule Firkin.PlugTest do
  use ExUnit.Case, async: false

  alias Firkin.Backends.Memory, as: MemoryBackend
  alias Firkin.Test.{NonStreamingBackend, SigV4Helper}

  @access_key "TESTKEY123"
  @secret_key "TESTSECRET456"

  setup do
    MemoryBackend.start()
    MemoryBackend.add_credential(@access_key, @secret_key)

    opts = Firkin.Plug.init(backend: MemoryBackend, region: "us-east-1")
    {:ok, opts: opts}
  end

  defp signed_conn(method, path, opts \\ []) do
    body = Keyword.get(opts, :body, "")
    headers = Keyword.get(opts, :headers, [])

    conn =
      Plug.Test.conn(method, path, body)
      |> Map.put(:req_headers, [{"host", "localhost"} | headers])

    SigV4Helper.sign_conn(conn, @access_key, @secret_key, body: body)
  end

  defp call(conn, opts) do
    Firkin.Plug.call(conn, opts)
  end

  describe "ListBuckets (GET /)" do
    test "returns empty list when no buckets", %{opts: opts} do
      conn = signed_conn(:get, "/") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "ListAllMyBucketsResult"
    end

    test "returns buckets after creation", %{opts: opts} do
      signed_conn(:put, "/test-bucket") |> call(opts)

      conn = signed_conn(:get, "/") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "test-bucket"
    end
  end

  describe "CreateBucket (PUT /{bucket})" do
    test "creates a bucket", %{opts: opts} do
      conn = signed_conn(:put, "/new-bucket") |> call(opts)
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "location") == ["/new-bucket"]
    end

    test "returns error for duplicate bucket", %{opts: opts} do
      signed_conn(:put, "/dup-bucket") |> call(opts)
      conn = signed_conn(:put, "/dup-bucket") |> call(opts)
      assert conn.status == 409
      assert conn.resp_body =~ "BucketAlreadyExists"
    end
  end

  describe "HeadBucket (HEAD /{bucket})" do
    test "returns 200 for existing bucket", %{opts: opts} do
      signed_conn(:put, "/head-bucket") |> call(opts)
      conn = signed_conn(:head, "/head-bucket") |> call(opts)
      assert conn.status == 200
    end

    test "returns 404 for non-existent bucket", %{opts: opts} do
      conn = signed_conn(:head, "/no-such-bucket") |> call(opts)
      assert conn.status == 404
    end
  end

  describe "DeleteBucket (DELETE /{bucket})" do
    test "deletes an empty bucket", %{opts: opts} do
      signed_conn(:put, "/del-bucket") |> call(opts)
      conn = signed_conn(:delete, "/del-bucket") |> call(opts)
      assert conn.status == 204
    end

    test "returns error for non-empty bucket", %{opts: opts} do
      signed_conn(:put, "/full-bucket") |> call(opts)

      signed_conn(:put, "/full-bucket/obj",
        body: "data",
        headers: [{"content-type", "text/plain"}]
      )
      |> call(opts)

      conn = signed_conn(:delete, "/full-bucket") |> call(opts)
      assert conn.status == 409
      assert conn.resp_body =~ "BucketNotEmpty"
    end
  end

  describe "GetBucketLocation (GET /{bucket}?location)" do
    test "returns location for existing bucket", %{opts: opts} do
      signed_conn(:put, "/loc-bucket") |> call(opts)
      conn = signed_conn(:get, "/loc-bucket?location") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "LocationConstraint"
      assert conn.resp_body =~ "us-east-1"
    end
  end

  describe "PutObject / GetObject / HeadObject / DeleteObject" do
    setup %{opts: opts} do
      signed_conn(:put, "/obj-bucket") |> call(opts)
      :ok
    end

    test "PutObject stores and GetObject retrieves", %{opts: opts} do
      body = "hello world"

      put_conn =
        signed_conn(:put, "/obj-bucket/test.txt",
          body: body,
          headers: [{"content-type", "text/plain"}]
        )
        |> call(opts)

      assert put_conn.status == 200
      assert [etag] = Plug.Conn.get_resp_header(put_conn, "etag")
      assert etag =~ ~r/^".+"$/

      get_conn = signed_conn(:get, "/obj-bucket/test.txt") |> call(opts)
      assert get_conn.status == 200
      assert get_conn.resp_body == "hello world"
      assert Plug.Conn.get_resp_header(get_conn, "content-type") == ["text/plain"]
    end

    test "HeadObject returns metadata without body", %{opts: opts} do
      signed_conn(:put, "/obj-bucket/head.txt",
        body: "12345",
        headers: [{"content-type", "text/plain"}]
      )
      |> call(opts)

      conn = signed_conn(:head, "/obj-bucket/head.txt") |> call(opts)
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-length") == ["5"]
      assert conn.resp_body == ""
    end

    test "DeleteObject removes the object", %{opts: opts} do
      signed_conn(:put, "/obj-bucket/del.txt", body: "data") |> call(opts)

      del_conn = signed_conn(:delete, "/obj-bucket/del.txt") |> call(opts)
      assert del_conn.status == 204

      get_conn = signed_conn(:get, "/obj-bucket/del.txt") |> call(opts)
      assert get_conn.status == 404
    end

    test "GetObject for non-existent key returns 404", %{opts: opts} do
      conn = signed_conn(:get, "/obj-bucket/nonexistent") |> call(opts)
      assert conn.status == 404
      assert conn.resp_body =~ "NoSuchKey"
    end

    test "GetObject with Range header returns 206 and partial content", %{opts: opts} do
      signed_conn(:put, "/obj-bucket/range.txt", body: "0123456789ABCDEF")
      |> call(opts)

      conn =
        signed_conn(:get, "/obj-bucket/range.txt", headers: [{"range", "bytes=5-9"}])
        |> call(opts)

      assert conn.status == 206
      assert conn.resp_body == "56789"
      assert [content_range] = Plug.Conn.get_resp_header(conn, "content-range")
      assert content_range =~ "bytes 5-9/"
      assert Plug.Conn.get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "GetObject without Range returns 200 with accept-ranges", %{opts: opts} do
      signed_conn(:put, "/obj-bucket/full.txt", body: "all content")
      |> call(opts)

      conn = signed_conn(:get, "/obj-bucket/full.txt") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body == "all content"
      assert Plug.Conn.get_resp_header(conn, "accept-ranges") == ["bytes"]
    end
  end

  describe "ListObjectsV2 (GET /{bucket})" do
    setup %{opts: opts} do
      signed_conn(:put, "/list-bucket") |> call(opts)

      for name <- ["a.txt", "b.txt", "dir/c.txt", "dir/d.txt"] do
        signed_conn(:put, "/list-bucket/#{name}", body: "data") |> call(opts)
      end

      :ok
    end

    test "lists all objects", %{opts: opts} do
      conn = signed_conn(:get, "/list-bucket?list-type=2") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "a.txt"
      assert conn.resp_body =~ "dir/c.txt"
    end

    test "filters by prefix", %{opts: opts} do
      conn = signed_conn(:get, "/list-bucket?list-type=2&prefix=dir/") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "dir/c.txt"
      refute conn.resp_body =~ "<Key>a.txt</Key>"
    end

    test "groups by delimiter", %{opts: opts} do
      conn = signed_conn(:get, "/list-bucket?list-type=2&delimiter=/") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "CommonPrefixes"
      assert conn.resp_body =~ "dir/"
    end
  end

  describe "CopyObject" do
    setup %{opts: opts} do
      signed_conn(:put, "/src-bucket") |> call(opts)
      signed_conn(:put, "/dst-bucket") |> call(opts)
      signed_conn(:put, "/src-bucket/original.txt", body: "original content") |> call(opts)
      :ok
    end

    test "copies object between buckets", %{opts: opts} do
      conn =
        signed_conn(:put, "/dst-bucket/copy.txt",
          headers: [{"x-amz-copy-source", "/src-bucket/original.txt"}]
        )
        |> call(opts)

      assert conn.status == 200
      assert conn.resp_body =~ "CopyObjectResult"

      get_conn = signed_conn(:get, "/dst-bucket/copy.txt") |> call(opts)
      assert get_conn.resp_body == "original content"
    end
  end

  describe "DeleteObjects (POST /{bucket}?delete)" do
    setup %{opts: opts} do
      signed_conn(:put, "/batch-bucket") |> call(opts)
      signed_conn(:put, "/batch-bucket/a.txt", body: "a") |> call(opts)
      signed_conn(:put, "/batch-bucket/b.txt", body: "b") |> call(opts)
      :ok
    end

    test "batch deletes objects", %{opts: opts} do
      body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Delete>
        <Object><Key>a.txt</Key></Object>
        <Object><Key>b.txt</Key></Object>
      </Delete>
      """

      conn =
        signed_conn(:post, "/batch-bucket?delete",
          body: body,
          headers: [{"content-type", "application/xml"}]
        )
        |> call(opts)

      assert conn.status == 200
      assert conn.resp_body =~ "DeleteResult"
      assert conn.resp_body =~ "a.txt"
    end
  end

  describe "Multipart upload" do
    setup %{opts: opts} do
      signed_conn(:put, "/mp-bucket") |> call(opts)
      :ok
    end

    test "full multipart upload lifecycle", %{opts: opts} do
      init_conn = signed_conn(:post, "/mp-bucket/large-file.bin?uploads") |> call(opts)
      assert init_conn.status == 200
      assert init_conn.resp_body =~ "InitiateMultipartUploadResult"

      upload_id = extract_xml_value(init_conn.resp_body, "UploadId")
      assert upload_id != nil

      part1_conn =
        signed_conn(:put, "/mp-bucket/large-file.bin?partNumber=1&uploadId=#{upload_id}",
          body: "part1-data"
        )
        |> call(opts)

      assert part1_conn.status == 200
      [etag1] = Plug.Conn.get_resp_header(part1_conn, "etag")

      part2_conn =
        signed_conn(:put, "/mp-bucket/large-file.bin?partNumber=2&uploadId=#{upload_id}",
          body: "part2-data"
        )
        |> call(opts)

      assert part2_conn.status == 200
      [etag2] = Plug.Conn.get_resp_header(part2_conn, "etag")

      parts_conn =
        signed_conn(:get, "/mp-bucket/large-file.bin?uploadId=#{upload_id}") |> call(opts)

      assert parts_conn.status == 200
      assert parts_conn.resp_body =~ "ListPartsResult"

      complete_body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <CompleteMultipartUpload>
        <Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>
        <Part><PartNumber>2</PartNumber><ETag>#{etag2}</ETag></Part>
      </CompleteMultipartUpload>
      """

      complete_conn =
        signed_conn(:post, "/mp-bucket/large-file.bin?uploadId=#{upload_id}",
          body: complete_body,
          headers: [{"content-type", "application/xml"}]
        )
        |> call(opts)

      assert complete_conn.status == 200
      assert complete_conn.resp_body =~ "CompleteMultipartUploadResult"

      get_conn = signed_conn(:get, "/mp-bucket/large-file.bin") |> call(opts)
      assert get_conn.status == 200
      assert get_conn.resp_body == "part1-datapart2-data"
    end

    test "abort multipart upload", %{opts: opts} do
      init_conn = signed_conn(:post, "/mp-bucket/abort.bin?uploads") |> call(opts)
      upload_id = extract_xml_value(init_conn.resp_body, "UploadId")

      abort_conn =
        signed_conn(:delete, "/mp-bucket/abort.bin?uploadId=#{upload_id}") |> call(opts)

      assert abort_conn.status == 204
    end

    test "list multipart uploads", %{opts: opts} do
      signed_conn(:post, "/mp-bucket/file1.bin?uploads") |> call(opts)
      signed_conn(:post, "/mp-bucket/file2.bin?uploads") |> call(opts)

      conn = signed_conn(:get, "/mp-bucket?uploads") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "ListMultipartUploadsResult"
    end
  end

  describe "Authentication" do
    test "rejects unsigned requests", %{opts: opts} do
      conn = Plug.Test.conn(:get, "/") |> Firkin.Plug.call(opts)
      assert conn.status == 403
      assert conn.resp_body =~ "SignatureDoesNotMatch"
    end

    test "rejects bad credentials", %{opts: opts} do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:req_headers, [{"host", "localhost"}])
        |> SigV4Helper.sign_conn("BADKEY", "BADSECRET")
        |> Firkin.Plug.call(opts)

      assert conn.status == 403
    end

    test "rejects tampered signature", %{opts: opts} do
      conn =
        signed_conn(:get, "/")
        |> Plug.Conn.put_req_header(
          "authorization",
          "AWS4-HMAC-SHA256 Credential=#{@access_key}/20240101/us-east-1/s3/aws4_request, " <>
            "SignedHeaders=host;x-amz-content-sha256;x-amz-date, " <>
            "Signature=0000000000000000000000000000000000000000000000000000000000000000"
        )
        |> Firkin.Plug.call(opts)

      assert conn.status == 403
    end
  end

  describe "Error handling" do
    test "returns XML error with request ID", %{opts: opts} do
      conn = signed_conn(:get, "/no-bucket/no-key") |> call(opts)
      assert conn.status == 404
      assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
      assert [req_id] = Plug.Conn.get_resp_header(conn, "x-amz-request-id")
      assert req_id =~ "firkin-"
    end
  end

  describe "User metadata" do
    setup %{opts: opts} do
      signed_conn(:put, "/meta-bucket") |> call(opts)
      :ok
    end

    test "round-trips x-amz-meta-* headers", %{opts: opts} do
      signed_conn(:put, "/meta-bucket/meta.txt",
        body: "data",
        headers: [
          {"content-type", "text/plain"},
          {"x-amz-meta-author", "test-user"},
          {"x-amz-meta-version", "42"}
        ]
      )
      |> call(opts)

      conn = signed_conn(:get, "/meta-bucket/meta.txt") |> call(opts)
      assert Plug.Conn.get_resp_header(conn, "x-amz-meta-author") == ["test-user"]
      assert Plug.Conn.get_resp_header(conn, "x-amz-meta-version") == ["42"]
    end
  end

  describe "virtual-hosted-style routing" do
    setup do
      vhost_opts =
        Firkin.Plug.init(
          backend: MemoryBackend,
          region: "us-east-1",
          hostname: "s3.example.com"
        )

      {:ok, vhost_opts: vhost_opts}
    end

    defp vhost_conn(method, path, host, opts \\ []) do
      body = Keyword.get(opts, :body, "")
      headers = [{"host", host} | Keyword.get(opts, :headers, [])]

      conn =
        Plug.Test.conn(method, path, body)
        |> Map.put(:req_headers, headers)

      SigV4Helper.sign_conn(conn, @access_key, @secret_key, body: body)
    end

    test "extracts bucket from Host header", %{vhost_opts: opts} do
      signed_conn(:put, "/vhost-bucket") |> call(opts)

      data = "virtual hosted data"

      vhost_conn(:put, "/greeting.txt", "vhost-bucket.s3.example.com",
        body: data,
        headers: [{"content-type", "text/plain"}]
      )
      |> call(opts)

      conn = vhost_conn(:get, "/greeting.txt", "vhost-bucket.s3.example.com") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body == data
    end

    test "falls back to path-style when Host does not match hostname", %{vhost_opts: opts} do
      signed_conn(:put, "/path-bucket") |> call(opts)

      conn =
        vhost_conn(:get, "/path-bucket", "other-host.example.com")
        |> call(opts)

      assert conn.status == 200
      assert conn.resp_body =~ "ListBucketResult"
    end

    test "falls back to path-style when hostname is not configured" do
      no_vhost_opts = Firkin.Plug.init(backend: MemoryBackend, region: "us-east-1")
      signed_conn(:put, "/novhost-bucket") |> call(no_vhost_opts)

      conn =
        vhost_conn(:get, "/novhost-bucket", "novhost-bucket.s3.example.com")
        |> call(no_vhost_opts)

      assert conn.status == 200
      assert conn.resp_body =~ "ListBucketResult"
    end

    test "Host with port is handled correctly", %{vhost_opts: opts} do
      signed_conn(:put, "/port-bucket") |> call(opts)

      conn =
        vhost_conn(:get, "/", "port-bucket.s3.example.com:4566")
        |> call(opts)

      assert conn.status == 200
      assert conn.resp_body =~ "ListBucketResult"
    end

    test "service-level ListBuckets via base hostname", %{vhost_opts: opts} do
      signed_conn(:put, "/lb-bucket") |> call(opts)

      conn = vhost_conn(:get, "/", "s3.example.com") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "ListAllMyBucketsResult"
    end

    test "bucket-level operations via virtual-hosted-style", %{vhost_opts: opts} do
      signed_conn(:put, "/ops-bucket") |> call(opts)

      conn = vhost_conn(:head, "/", "ops-bucket.s3.example.com") |> call(opts)
      assert conn.status == 200

      conn = vhost_conn(:get, "/", "ops-bucket.s3.example.com") |> call(opts)
      assert conn.status == 200
      assert conn.resp_body =~ "ListBucketResult"
    end

    test "nested key paths work with virtual-hosted-style", %{vhost_opts: opts} do
      signed_conn(:put, "/nested-bucket") |> call(opts)

      data = "nested content"

      vhost_conn(:put, "/path/to/deep/file.txt", "nested-bucket.s3.example.com",
        body: data,
        headers: [{"content-type", "text/plain"}]
      )
      |> call(opts)

      conn =
        vhost_conn(:get, "/path/to/deep/file.txt", "nested-bucket.s3.example.com")
        |> call(opts)

      assert conn.status == 200
      assert conn.resp_body == data
    end
  end

  describe "conditional requests" do
    setup %{opts: opts} do
      signed_conn(:put, "/cond-bucket") |> call(opts)

      signed_conn(:put, "/cond-bucket/file.txt",
        body: "conditional content",
        headers: [{"content-type", "text/plain"}]
      )
      |> call(opts)

      get_conn = signed_conn(:get, "/cond-bucket/file.txt") |> call(opts)
      [etag] = Plug.Conn.get_resp_header(get_conn, "etag")
      [last_modified] = Plug.Conn.get_resp_header(get_conn, "last-modified")

      {:ok, etag: etag, last_modified: last_modified}
    end

    test "If-None-Match with matching etag returns 304", %{opts: opts, etag: etag} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt", headers: [{"if-none-match", etag}])
        |> call(opts)

      assert conn.status == 304
    end

    test "If-None-Match with non-matching etag returns 200", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-none-match", "\"nonexistent\""}]
        )
        |> call(opts)

      assert conn.status == 200
    end

    test "If-None-Match with wildcard returns 304", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt", headers: [{"if-none-match", "*"}])
        |> call(opts)

      assert conn.status == 304
    end

    test "If-Match with matching etag returns 200", %{opts: opts, etag: etag} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt", headers: [{"if-match", etag}])
        |> call(opts)

      assert conn.status == 200
    end

    test "If-Match with non-matching etag returns 412", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt", headers: [{"if-match", "\"wrong-etag\""}])
        |> call(opts)

      assert conn.status == 412
    end

    test "If-Modified-Since with old date returns 200", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-modified-since", "Mon, 01 Jan 2024 00:00:00 GMT"}]
        )
        |> call(opts)

      assert conn.status == 200
    end

    test "If-Modified-Since with future date returns 304", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-modified-since", "Fri, 01 Jan 2100 00:00:00 GMT"}]
        )
        |> call(opts)

      assert conn.status == 304
    end

    test "If-Unmodified-Since with future date returns 200", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-unmodified-since", "Fri, 01 Jan 2100 00:00:00 GMT"}]
        )
        |> call(opts)

      assert conn.status == 200
    end

    test "If-Unmodified-Since with old date returns 412", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-unmodified-since", "Mon, 01 Jan 2024 00:00:00 GMT"}]
        )
        |> call(opts)

      assert conn.status == 412
    end

    test "If-None-Match takes precedence over If-Modified-Since", %{opts: opts, etag: etag} do
      # Per RFC 7232: If-None-Match present → If-Modified-Since is ignored
      # Etag matches (→ 304), but date is old (→ would be 200 if evaluated)
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [
            {"if-none-match", etag},
            {"if-modified-since", "Mon, 01 Jan 2024 00:00:00 GMT"}
          ]
        )
        |> call(opts)

      assert conn.status == 304
    end

    test "If-Match takes precedence over If-Unmodified-Since", %{opts: opts, etag: etag} do
      # Per RFC 7232: If-Match present → If-Unmodified-Since is ignored
      # Etag matches (→ ok), but date is old (→ would be 412 if evaluated)
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [
            {"if-match", etag},
            {"if-unmodified-since", "Mon, 01 Jan 2024 00:00:00 GMT"}
          ]
        )
        |> call(opts)

      assert conn.status == 200
    end

    test "If-None-Match with multiple etags", %{opts: opts, etag: etag} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-none-match", "\"other\", #{etag}, \"another\""}]
        )
        |> call(opts)

      assert conn.status == 304
    end

    test "conditional headers work with HEAD requests", %{opts: opts, etag: etag} do
      conn =
        signed_conn(:head, "/cond-bucket/file.txt", headers: [{"if-none-match", etag}])
        |> call(opts)

      assert conn.status == 304
    end

    test "HEAD with If-Unmodified-Since old date returns 412", %{opts: opts} do
      conn =
        signed_conn(:head, "/cond-bucket/file.txt",
          headers: [{"if-unmodified-since", "Mon, 01 Jan 2024 00:00:00 GMT"}]
        )
        |> call(opts)

      assert conn.status == 412
    end

    test "invalid date in If-Modified-Since is ignored", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt", headers: [{"if-modified-since", "not a date"}])
        |> call(opts)

      assert conn.status == 200
    end

    test "RFC 850 date format is parsed", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-modified-since", "Monday, 01-Jan-24 00:00:00 GMT"}]
        )
        |> call(opts)

      assert conn.status == 200
    end

    test "asctime date format is parsed", %{opts: opts} do
      conn =
        signed_conn(:get, "/cond-bucket/file.txt",
          headers: [{"if-modified-since", "Mon Jan  1 00:00:00 2024"}]
        )
        |> call(opts)

      assert conn.status == 200
    end
  end

  describe "PUT/UploadPart streaming and cap" do
    setup do
      opts =
        Firkin.Plug.init(
          backend: NonStreamingBackend,
          region: "us-east-1",
          max_buffered_put_bytes: 32
        )

      NonStreamingBackend.start()
      NonStreamingBackend.add_credential(@access_key, @secret_key)
      signed_conn(:put, "/cap-bucket") |> call(opts)

      {:ok, cap_opts: opts}
    end

    test "PutObject body under the cap goes through the buffered path", %{cap_opts: opts} do
      body = String.duplicate("a", 20)

      conn =
        signed_conn(:put, "/cap-bucket/small.txt", body: body)
        |> call(opts)

      assert conn.status == 200
      assert [_etag] = Plug.Conn.get_resp_header(conn, "etag")
    end

    test "PutObject body exceeding the cap returns 400 EntityTooLarge", %{cap_opts: opts} do
      body = String.duplicate("a", 128)

      conn =
        signed_conn(:put, "/cap-bucket/big.txt", body: body)
        |> call(opts)

      assert conn.status == 400
      assert conn.resp_body =~ "EntityTooLarge"
      assert conn.resp_body =~ "put_object_stream"
    end

    test "UploadPart body exceeding the cap returns 400 EntityTooLarge", %{cap_opts: opts} do
      init_conn = signed_conn(:post, "/cap-bucket/multi.bin?uploads") |> call(opts)
      upload_id = extract_xml_value(init_conn.resp_body, "UploadId")

      body = String.duplicate("b", 128)

      part_conn =
        signed_conn(:put, "/cap-bucket/multi.bin?partNumber=1&uploadId=#{upload_id}", body: body)
        |> call(opts)

      assert part_conn.status == 400
      assert part_conn.resp_body =~ "EntityTooLarge"
    end

    test "PutObject on a streaming backend bypasses the cap", %{opts: opts} do
      signed_conn(:put, "/stream-bucket") |> call(opts)

      # MemoryBackend implements put_object_stream so uploads beyond any
      # configured cap still work — the bytes are streamed, not buffered.
      big_opts =
        Firkin.Plug.init(
          backend: MemoryBackend,
          region: "us-east-1",
          max_buffered_put_bytes: 8
        )

      body = String.duplicate("x", 1_024)

      conn =
        signed_conn(:put, "/stream-bucket/big.txt", body: body)
        |> call(big_opts)

      assert conn.status == 200
    end
  end

  defp extract_xml_value(xml, tag) do
    case Regex.run(~r/<#{tag}>([^<]+)<\/#{tag}>/, xml) do
      [_, value] -> value
      _ -> nil
    end
  end
end
