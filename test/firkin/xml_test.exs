defmodule Firkin.XMLTest do
  use ExUnit.Case, async: true

  alias Firkin.XML

  describe "list_buckets_response/1" do
    test "generates valid XML with buckets" do
      buckets = [
        %Firkin.Bucket{name: "bucket-1", creation_date: ~U[2024-01-15 10:30:00Z]},
        %Firkin.Bucket{name: "bucket-2", creation_date: ~U[2024-06-20 14:00:00Z]}
      ]

      xml = XML.list_buckets_response(buckets)
      assert xml =~ "ListAllMyBucketsResult"
      assert xml =~ "bucket-1"
      assert xml =~ "bucket-2"
      assert xml =~ "2024-01-15"
    end
  end

  describe "list_objects_v2_response/1" do
    test "generates valid XML with contents and prefixes" do
      result = %Firkin.ListResult{
        name: "my-bucket",
        prefix: "photos/",
        delimiter: "/",
        contents: [
          %Firkin.ObjectMeta{
            key: "photos/pic1.jpg",
            etag: "abc123",
            size: 1024,
            last_modified: ~U[2024-03-01 12:00:00Z]
          }
        ],
        common_prefixes: ["photos/2024/"],
        key_count: 1,
        max_keys: 1000,
        is_truncated: false
      }

      xml = XML.list_objects_v2_response(result)
      assert xml =~ "ListBucketResult"
      assert xml =~ "my-bucket"
      assert xml =~ "photos/pic1.jpg"
      assert xml =~ "\"abc123\""
      assert xml =~ "photos/2024/"
      assert xml =~ "<IsTruncated>false</IsTruncated>"
    end
  end

  describe "error_response/1" do
    test "generates valid error XML" do
      error = %Firkin.Error{
        code: :no_such_key,
        message: "Object not found",
        resource: "/bucket/key"
      }

      xml = XML.error_response(error)
      assert xml =~ "<Code>NoSuchKey</Code>"
      assert xml =~ "<Message>Object not found</Message>"
      assert xml =~ "<Resource>/bucket/key</Resource>"
    end

    test "uses default message when none provided" do
      error = %Firkin.Error{code: :access_denied}
      xml = XML.error_response(error)
      assert xml =~ "<Message>Access Denied</Message>"
    end
  end

  describe "copy_object_response/1" do
    test "generates valid copy result XML" do
      result = %Firkin.CopyResult{
        etag: "abc123",
        last_modified: ~U[2024-06-15 10:00:00Z]
      }

      xml = XML.copy_object_response(result)
      assert xml =~ "CopyObjectResult"
      assert xml =~ "\"abc123\""
    end
  end

  describe "parse_delete_objects/1" do
    test "parses valid DeleteObjects XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Delete>
        <Object><Key>file1.txt</Key></Object>
        <Object><Key>file2.txt</Key></Object>
      </Delete>
      """

      assert {:ok, keys} = XML.parse_delete_objects(xml)
      assert keys == ["file1.txt", "file2.txt"]
    end

    test "returns error for invalid XML" do
      assert {:error, :invalid_xml} = XML.parse_delete_objects("not xml")
    end
  end

  describe "parse_complete_multipart/1" do
    test "parses valid CompleteMultipartUpload XML" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <CompleteMultipartUpload>
        <Part>
          <PartNumber>1</PartNumber>
          <ETag>"abc123"</ETag>
        </Part>
        <Part>
          <PartNumber>2</PartNumber>
          <ETag>"def456"</ETag>
        </Part>
      </CompleteMultipartUpload>
      """

      assert {:ok, parts} = XML.parse_complete_multipart(xml)
      assert parts == [{1, "abc123"}, {2, "def456"}]
    end
  end

  describe "initiate_multipart_upload_response/3" do
    test "generates valid XML" do
      xml = XML.initiate_multipart_upload_response("my-bucket", "my-key", "upload-123")
      assert xml =~ "InitiateMultipartUploadResult"
      assert xml =~ "<Bucket>my-bucket</Bucket>"
      assert xml =~ "<Key>my-key</Key>"
      assert xml =~ "<UploadId>upload-123</UploadId>"
    end
  end

  describe "delete_objects_response/1" do
    test "generates valid XML with deleted and errors" do
      result = %Firkin.DeleteResult{
        deleted: [%{key: "file1.txt"}],
        errors: [%{key: "file2.txt", code: "AccessDenied", message: "Denied"}]
      }

      xml = XML.delete_objects_response(result)
      assert xml =~ "DeleteResult"
      assert xml =~ "<Key>file1.txt</Key>"
      assert xml =~ "<Code>AccessDenied</Code>"
    end
  end
end
