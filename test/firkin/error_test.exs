defmodule Firkin.ErrorTest do
  use ExUnit.Case, async: true

  alias Firkin.Error

  describe "to_http_status/1" do
    test "maps all error codes to correct HTTP status" do
      assert Error.to_http_status(:access_denied) == 403
      assert Error.to_http_status(:signature_does_not_match) == 403
      assert Error.to_http_status(:no_such_bucket) == 404
      assert Error.to_http_status(:no_such_key) == 404
      assert Error.to_http_status(:no_such_upload) == 404
      assert Error.to_http_status(:bucket_already_exists) == 409
      assert Error.to_http_status(:bucket_not_empty) == 409
      assert Error.to_http_status(:invalid_argument) == 400
      assert Error.to_http_status(:invalid_bucket_name) == 400
      assert Error.to_http_status(:entity_too_large) == 400
      assert Error.to_http_status(:invalid_part) == 400
      assert Error.to_http_status(:invalid_part_order) == 400
      assert Error.to_http_status(:precondition_failed) == 412
      assert Error.to_http_status(:not_modified) == 304
      assert Error.to_http_status(:internal_error) == 500
      assert Error.to_http_status(:not_implemented) == 501
    end
  end

  describe "to_s3_code/1" do
    test "maps error codes to S3 code strings" do
      assert Error.to_s3_code(:no_such_key) == "NoSuchKey"
      assert Error.to_s3_code(:access_denied) == "AccessDenied"
      assert Error.to_s3_code(:internal_error) == "InternalError"
    end
  end
end
