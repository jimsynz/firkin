defmodule Firkin.ExternalClientTest do
  @moduledoc """
  Tests Firkin compatibility using ExAws.S3, a real third-party S3 client.

  These tests start an actual HTTP server (Bandit) and exercise every
  implemented endpoint through the external client to verify wire-level
  compatibility with the S3 protocol. Assertions focus on parsed response
  bodies — not just status codes — to ensure the XML responses are
  structurally correct for real client consumption.
  """
  use ExUnit.Case, async: false

  alias Firkin.Backends.Memory, as: MemoryBackend
  alias Firkin.Test.TestServer

  @access_key "EXTTEST123"
  @secret_key "EXTSECRET456"

  setup do
    MemoryBackend.start()
    MemoryBackend.add_credential(@access_key, @secret_key)
    {:ok, port} = TestServer.start()
    config = TestServer.ex_aws_config(port, @access_key, @secret_key)
    {:ok, config: config}
  end

  defp request!(op, config) do
    case ExAws.request(op, config) do
      {:ok, result} -> result
      {:error, reason} -> raise "ExAws request failed: #{inspect(reason)}"
    end
  end

  describe "bucket operations" do
    test "create, head, list, get location, and delete a bucket", %{config: config} do
      ExAws.S3.put_bucket("ext-bucket", "us-east-1") |> request!(config)

      assert %{status_code: 200} = ExAws.S3.head_bucket("ext-bucket") |> request!(config)

      result = ExAws.S3.list_buckets() |> request!(config)
      assert [%{name: "ext-bucket", creation_date: creation_date}] = result.body.buckets
      assert is_binary(creation_date) and creation_date != ""

      result = ExAws.S3.get_bucket_location("ext-bucket") |> request!(config)
      assert result.body =~ "us-east-1"
      assert result.body =~ "LocationConstraint"

      assert %{status_code: 204} = ExAws.S3.delete_bucket("ext-bucket") |> request!(config)

      assert {:error, {:http_error, 404, _}} =
               ExAws.S3.head_bucket("ext-bucket") |> ExAws.request(config)
    end

    test "list buckets returns multiple buckets sorted", %{config: config} do
      for name <- ["charlie", "alpha", "bravo"] do
        ExAws.S3.put_bucket(name, "us-east-1") |> request!(config)
      end

      result = ExAws.S3.list_buckets() |> request!(config)
      names = Enum.map(result.body.buckets, & &1.name)
      assert names == ["alpha", "bravo", "charlie"]
    end

    test "head non-existent bucket returns 404", %{config: config} do
      assert {:error, {:http_error, 404, _}} =
               ExAws.S3.head_bucket("no-such-bucket") |> ExAws.request(config)
    end

    test "delete non-empty bucket returns 409", %{config: config} do
      ExAws.S3.put_bucket("nonempty", "us-east-1") |> request!(config)
      ExAws.S3.put_object("nonempty", "file.txt", "data") |> request!(config)

      assert {:error, {:http_error, 409, _}} =
               ExAws.S3.delete_bucket("nonempty") |> ExAws.request(config)
    end

    test "creating duplicate bucket returns 409", %{config: config} do
      ExAws.S3.put_bucket("dup", "us-east-1") |> request!(config)

      assert {:error, {:http_error, 409, _}} =
               ExAws.S3.put_bucket("dup", "us-east-1") |> ExAws.request(config)
    end
  end

  describe "object operations" do
    setup %{config: config} do
      ExAws.S3.put_bucket("obj-bucket", "us-east-1") |> request!(config)
      :ok
    end

    test "put and get object round-trips body and content-type", %{config: config} do
      body = "hello from ex_aws"

      put_result =
        ExAws.S3.put_object("obj-bucket", "greeting.txt", body, content_type: "text/plain")
        |> request!(config)

      etag = get_header(put_result, "etag")
      assert etag =~ ~r/^"[a-f0-9]+"$/

      get_result = ExAws.S3.get_object("obj-bucket", "greeting.txt") |> request!(config)
      assert get_result.body == body
      assert get_header(get_result, "content-type") == "text/plain"
      assert get_header(get_result, "etag") == etag
    end

    test "head object returns content-length and etag", %{config: config} do
      ExAws.S3.put_object("obj-bucket", "head-test.txt", "12345", content_type: "text/plain")
      |> request!(config)

      result = ExAws.S3.head_object("obj-bucket", "head-test.txt") |> request!(config)
      assert get_header(result, "content-length") == "5"
      assert get_header(result, "content-type") == "text/plain"
      assert get_header(result, "etag") =~ ~r/^"[a-f0-9]+"$/
    end

    test "delete object removes it", %{config: config} do
      ExAws.S3.put_object("obj-bucket", "to-delete.txt", "bye") |> request!(config)

      assert %{status_code: 204} =
               ExAws.S3.delete_object("obj-bucket", "to-delete.txt") |> request!(config)

      assert {:error, {:http_error, 404, _}} =
               ExAws.S3.get_object("obj-bucket", "to-delete.txt") |> ExAws.request(config)
    end

    test "get non-existent object returns 404", %{config: config} do
      assert {:error, {:http_error, 404, _}} =
               ExAws.S3.get_object("obj-bucket", "nope") |> ExAws.request(config)
    end

    test "put and get object with nested key", %{config: config} do
      ExAws.S3.put_object("obj-bucket", "path/to/nested/file.txt", "nested content")
      |> request!(config)

      result = ExAws.S3.get_object("obj-bucket", "path/to/nested/file.txt") |> request!(config)
      assert result.body == "nested content"
    end

    test "overwrite existing object updates body and etag", %{config: config} do
      put1 = ExAws.S3.put_object("obj-bucket", "overwrite.txt", "v1") |> request!(config)
      put2 = ExAws.S3.put_object("obj-bucket", "overwrite.txt", "v2") |> request!(config)

      assert get_header(put1, "etag") != get_header(put2, "etag")

      result = ExAws.S3.get_object("obj-bucket", "overwrite.txt") |> request!(config)
      assert result.body == "v2"
      assert get_header(result, "etag") == get_header(put2, "etag")
    end

    test "empty body object", %{config: config} do
      ExAws.S3.put_object("obj-bucket", "empty.txt", "") |> request!(config)

      result = ExAws.S3.get_object("obj-bucket", "empty.txt") |> request!(config)
      assert result.body == ""

      head = ExAws.S3.head_object("obj-bucket", "empty.txt") |> request!(config)
      assert get_header(head, "content-length") == "0"
    end
  end

  describe "copy object" do
    setup %{config: config} do
      ExAws.S3.put_bucket("src-bucket", "us-east-1") |> request!(config)
      ExAws.S3.put_bucket("dst-bucket", "us-east-1") |> request!(config)
      ExAws.S3.put_object("src-bucket", "original.txt", "original data") |> request!(config)
      :ok
    end

    test "copies object between buckets preserving body", %{config: config} do
      result =
        ExAws.S3.put_object_copy("dst-bucket", "copied.txt", "src-bucket", "original.txt")
        |> request!(config)

      assert result.status_code == 200

      get_result = ExAws.S3.get_object("dst-bucket", "copied.txt") |> request!(config)
      assert get_result.body == "original data"

      source = ExAws.S3.get_object("src-bucket", "original.txt") |> request!(config)
      assert source.body == "original data"
    end

    test "copies object within same bucket", %{config: config} do
      ExAws.S3.put_object_copy("src-bucket", "copy.txt", "src-bucket", "original.txt")
      |> request!(config)

      result = ExAws.S3.get_object("src-bucket", "copy.txt") |> request!(config)
      assert result.body == "original data"
    end

    test "copy preserves etag of content", %{config: config} do
      source_head = ExAws.S3.head_object("src-bucket", "original.txt") |> request!(config)
      source_etag = get_header(source_head, "etag")

      ExAws.S3.put_object_copy("dst-bucket", "copied.txt", "src-bucket", "original.txt")
      |> request!(config)

      dest_head = ExAws.S3.head_object("dst-bucket", "copied.txt") |> request!(config)
      assert get_header(dest_head, "etag") == source_etag
    end
  end

  describe "list objects" do
    setup %{config: config} do
      ExAws.S3.put_bucket("list-bucket", "us-east-1") |> request!(config)

      for name <- ["a.txt", "b.txt", "dir/c.txt", "dir/d.txt", "dir/sub/e.txt"] do
        ExAws.S3.put_object("list-bucket", name, "data-#{name}") |> request!(config)
      end

      :ok
    end

    test "list_objects_v2 returns all objects with parsed metadata", %{config: config} do
      result = ExAws.S3.list_objects_v2("list-bucket") |> request!(config)
      body = result.body

      assert body.name == "list-bucket"
      assert body.max_keys == "1000"
      assert body.key_count == "5"
      assert body.is_truncated == "false"

      keys = Enum.map(body.contents, & &1.key)
      assert keys == ["a.txt", "b.txt", "dir/c.txt", "dir/d.txt", "dir/sub/e.txt"]

      first = hd(body.contents)
      assert first.key == "a.txt"
      assert first.e_tag =~ ~r/^"[a-f0-9]+"$/
      assert first.size == "10"
      assert first.storage_class == "STANDARD"
      assert first.last_modified != ""
    end

    test "list_objects_v2 with prefix filter", %{config: config} do
      result = ExAws.S3.list_objects_v2("list-bucket", prefix: "dir/") |> request!(config)
      body = result.body

      assert body.prefix == "dir/"
      keys = Enum.map(body.contents, & &1.key)
      assert keys == ["dir/c.txt", "dir/d.txt", "dir/sub/e.txt"]
      refute "a.txt" in keys
    end

    test "list_objects_v2 with delimiter groups common prefixes", %{config: config} do
      result =
        ExAws.S3.list_objects_v2("list-bucket", delimiter: "/") |> request!(config)

      body = result.body
      keys = Enum.map(body.contents, & &1.key)
      assert keys == ["a.txt", "b.txt"]

      assert [%{prefix: "dir/"}] = body.common_prefixes
    end

    test "list_objects_v2 with prefix and delimiter", %{config: config} do
      result =
        ExAws.S3.list_objects_v2("list-bucket", prefix: "dir/", delimiter: "/")
        |> request!(config)

      body = result.body
      keys = Enum.map(body.contents, & &1.key)
      assert keys == ["dir/c.txt", "dir/d.txt"]

      assert [%{prefix: "dir/sub/"}] = body.common_prefixes
    end

    test "list_objects_v2 on empty bucket", %{config: config} do
      ExAws.S3.put_bucket("empty-bucket", "us-east-1") |> request!(config)

      result = ExAws.S3.list_objects_v2("empty-bucket") |> request!(config)
      assert result.body.contents == []
      assert result.body.key_count == "0"
    end
  end

  describe "batch delete" do
    setup %{config: config} do
      ExAws.S3.put_bucket("batch-bucket", "us-east-1") |> request!(config)
      ExAws.S3.put_object("batch-bucket", "x.txt", "x") |> request!(config)
      ExAws.S3.put_object("batch-bucket", "y.txt", "y") |> request!(config)
      ExAws.S3.put_object("batch-bucket", "z.txt", "z") |> request!(config)
      :ok
    end

    test "delete_multiple_objects removes specified objects only", %{config: config} do
      result =
        ExAws.S3.delete_multiple_objects("batch-bucket", ["x.txt", "y.txt"])
        |> request!(config)

      assert result.status_code == 200
      assert result.body =~ "x.txt"
      assert result.body =~ "y.txt"

      z_result = ExAws.S3.get_object("batch-bucket", "z.txt") |> request!(config)
      assert z_result.body == "z"

      assert {:error, {:http_error, 404, _}} =
               ExAws.S3.get_object("batch-bucket", "x.txt") |> ExAws.request(config)

      assert {:error, {:http_error, 404, _}} =
               ExAws.S3.get_object("batch-bucket", "y.txt") |> ExAws.request(config)
    end
  end

  describe "multipart upload" do
    setup %{config: config} do
      ExAws.S3.put_bucket("mp-bucket", "us-east-1") |> request!(config)
      :ok
    end

    test "full multipart upload lifecycle with parsed responses", %{config: config} do
      init_result =
        ExAws.S3.initiate_multipart_upload("mp-bucket", "large.bin") |> request!(config)

      assert init_result.body.bucket == "mp-bucket"
      assert init_result.body.key == "large.bin"
      upload_id = init_result.body.upload_id
      assert is_binary(upload_id) and upload_id != ""

      part1_result =
        ExAws.S3.upload_part("mp-bucket", "large.bin", upload_id, 1, "part-one-")
        |> request!(config)

      etag1 = get_header(part1_result, "etag")
      assert etag1 =~ ~r/^"[a-f0-9]+"$/

      part2_result =
        ExAws.S3.upload_part("mp-bucket", "large.bin", upload_id, 2, "part-two")
        |> request!(config)

      etag2 = get_header(part2_result, "etag")
      assert etag1 != etag2

      parts_result =
        ExAws.S3.list_parts("mp-bucket", "large.bin", upload_id) |> request!(config)

      assert [part1, part2] = parts_result.body.parts
      assert part1.part_number == "1"
      assert part1.etag =~ ~r/"?[a-f0-9]+"?/
      assert part1.size == "9"
      assert part2.part_number == "2"
      assert part2.size == "8"

      complete_result =
        ExAws.S3.complete_multipart_upload(
          "mp-bucket",
          "large.bin",
          upload_id,
          %{1 => etag1, 2 => etag2}
        )
        |> request!(config)

      assert complete_result.body.bucket == "mp-bucket"
      assert complete_result.body.key == "large.bin"
      assert complete_result.body.etag =~ ~r/"?[a-f0-9]+"?/

      get_result = ExAws.S3.get_object("mp-bucket", "large.bin") |> request!(config)
      assert get_result.body == "part-one-part-two"
      assert get_header(get_result, "content-length") == "17"
    end

    test "abort multipart upload", %{config: config} do
      init_result =
        ExAws.S3.initiate_multipart_upload("mp-bucket", "abort.bin") |> request!(config)

      upload_id = init_result.body.upload_id

      assert %{status_code: 204} =
               ExAws.S3.abort_multipart_upload("mp-bucket", "abort.bin", upload_id)
               |> request!(config)
    end

    test "list multipart uploads returns parsed upload entries", %{config: config} do
      init1 =
        ExAws.S3.initiate_multipart_upload("mp-bucket", "file1.bin") |> request!(config)

      init2 =
        ExAws.S3.initiate_multipart_upload("mp-bucket", "file2.bin") |> request!(config)

      result = ExAws.S3.list_multipart_uploads("mp-bucket") |> request!(config)
      assert result.body.bucket == "mp-bucket"

      upload_keys = Enum.map(result.body.uploads, & &1.key) |> Enum.sort()
      assert upload_keys == ["file1.bin", "file2.bin"]

      upload_ids = Enum.map(result.body.uploads, & &1.upload_id) |> Enum.sort()
      assert upload_ids == Enum.sort([init1.body.upload_id, init2.body.upload_id])
    end
  end

  describe "user metadata" do
    setup %{config: config} do
      ExAws.S3.put_bucket("meta-bucket", "us-east-1") |> request!(config)
      :ok
    end

    test "round-trips x-amz-meta-* headers on head", %{config: config} do
      ExAws.S3.put_object("meta-bucket", "meta.txt", "data",
        meta: [author: "test-user", version: "42"]
      )
      |> request!(config)

      result = ExAws.S3.head_object("meta-bucket", "meta.txt") |> request!(config)
      assert get_header(result, "x-amz-meta-author") == "test-user"
      assert get_header(result, "x-amz-meta-version") == "42"
    end

    test "round-trips x-amz-meta-* headers on get", %{config: config} do
      ExAws.S3.put_object("meta-bucket", "meta2.txt", "data", meta: [project: "firkin"])
      |> request!(config)

      result = ExAws.S3.get_object("meta-bucket", "meta2.txt") |> request!(config)
      assert get_header(result, "x-amz-meta-project") == "firkin"
    end
  end

  describe "conditional requests" do
    setup %{config: config} do
      ExAws.S3.put_bucket("cond-bucket", "us-east-1") |> request!(config)

      ExAws.S3.put_object("cond-bucket", "file.txt", "conditional content",
        content_type: "text/plain"
      )
      |> request!(config)

      head = ExAws.S3.head_object("cond-bucket", "file.txt") |> request!(config)
      etag = get_header(head, "etag")
      last_modified = get_header(head, "last-modified")

      {:ok, etag: etag, last_modified: last_modified}
    end

    test "if-none-match with matching etag returns 304 with empty body", %{
      config: config,
      etag: etag
    } do
      result =
        ExAws.S3.get_object("cond-bucket", "file.txt", if_none_match: etag)
        |> request!(config)

      assert result.status_code == 304
      assert result.body == "" or result.body == nil
    end

    test "if-match with matching etag returns full object", %{config: config, etag: etag} do
      result =
        ExAws.S3.get_object("cond-bucket", "file.txt", if_match: etag) |> request!(config)

      assert result.status_code == 200
      assert result.body == "conditional content"
    end

    test "if-match with wrong etag returns 412", %{config: config} do
      assert {:error, {:http_error, 412, _}} =
               ExAws.S3.get_object("cond-bucket", "file.txt", if_match: "\"wrong\"")
               |> ExAws.request(config)
    end

    test "if-modified-since with old date returns full object", %{config: config} do
      result =
        ExAws.S3.get_object("cond-bucket", "file.txt",
          if_modified_since: "Mon, 01 Jan 2024 00:00:00 GMT"
        )
        |> request!(config)

      assert result.status_code == 200
      assert result.body == "conditional content"
    end

    test "if-unmodified-since with old date returns 412", %{config: config} do
      assert {:error, {:http_error, 412, _}} =
               ExAws.S3.get_object("cond-bucket", "file.txt",
                 if_unmodified_since: "Mon, 01 Jan 2024 00:00:00 GMT"
               )
               |> ExAws.request(config)
    end
  end

  describe "error responses" do
    test "operations on non-existent bucket return proper errors", %{config: config} do
      assert {:error, {:http_error, 404, %{body: body}}} =
               ExAws.S3.get_object("no-bucket", "no-key") |> ExAws.request(config)

      assert body =~ "NoSuchKey"
    end

    test "bad credentials return 403", %{config: config} do
      bad_config = Keyword.merge(config, access_key_id: "BAD", secret_access_key: "WRONG")

      assert {:error, {:http_error, 403, %{body: body}}} =
               ExAws.S3.list_buckets() |> ExAws.request(bad_config)

      assert body =~ "<Error>"
    end
  end

  defp get_header(%{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp get_header(%{headers: headers}, name) when is_map(headers) do
    Map.get(headers, name)
  end
end
