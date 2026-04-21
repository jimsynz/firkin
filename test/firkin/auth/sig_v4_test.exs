defmodule Firkin.Auth.SigV4Test do
  use ExUnit.Case, async: true

  alias Firkin.Auth.SigV4

  describe "parse_auth_header/1" do
    test "parses a valid AWS4-HMAC-SHA256 header" do
      header =
        "AWS4-HMAC-SHA256 " <>
          "Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request, " <>
          "SignedHeaders=host;x-amz-content-sha256;x-amz-date, " <>
          "Signature=abc123def456"

      assert {:ok, parsed} = SigV4.parse_auth_header(header)
      assert parsed.access_key_id == "AKIDEXAMPLE"
      assert parsed.date == "20150830"
      assert parsed.region == "us-east-1"
      assert parsed.service == "s3"
      assert parsed.signed_headers == ["host", "x-amz-content-sha256", "x-amz-date"]
      assert parsed.signature == "abc123def456"
      assert parsed.credential_scope == "20150830/us-east-1/s3/aws4_request"
    end

    test "rejects non-SigV4 header" do
      assert {:error, :invalid_signature} = SigV4.parse_auth_header("Basic dXNlcjpwYXNz")
    end

    test "rejects malformed credential" do
      header = "AWS4-HMAC-SHA256 Credential=bad, SignedHeaders=host, Signature=abc"
      assert {:error, :invalid_signature} = SigV4.parse_auth_header(header)
    end
  end

  describe "parse_presigned_params/1" do
    test "parses valid presigned URL parameters" do
      params = %{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request",
        "X-Amz-SignedHeaders" => "host",
        "X-Amz-Signature" => "abc123",
        "X-Amz-Date" => "20150830T123600Z",
        "X-Amz-Expires" => "3600"
      }

      assert {:ok, parsed} = SigV4.parse_presigned_params(params)
      assert parsed.access_key_id == "AKIDEXAMPLE"
      assert parsed.expires == 3600
      assert parsed.amz_date == "20150830T123600Z"
    end

    test "rejects missing algorithm" do
      params = %{"X-Amz-Credential" => "AKID/20150830/us-east-1/s3/aws4_request"}
      assert {:error, :invalid_signature} = SigV4.parse_presigned_params(params)
    end
  end

  describe "derive_signing_key/4" do
    test "derives deterministic key" do
      key1 = SigV4.derive_signing_key("secret", "20150830", "us-east-1", "s3")
      key2 = SigV4.derive_signing_key("secret", "20150830", "us-east-1", "s3")
      assert key1 == key2
    end

    test "different secrets produce different keys" do
      key1 = SigV4.derive_signing_key("secret1", "20150830", "us-east-1", "s3")
      key2 = SigV4.derive_signing_key("secret2", "20150830", "us-east-1", "s3")
      assert key1 != key2
    end
  end

  describe "build_string_to_sign/3" do
    test "builds correct format" do
      result =
        SigV4.build_string_to_sign(
          "20150830T123600Z",
          "20150830/us-east-1/s3/aws4_request",
          "canonical-request-content"
        )

      lines = String.split(result, "\n")
      assert Enum.at(lines, 0) == "AWS4-HMAC-SHA256"
      assert Enum.at(lines, 1) == "20150830T123600Z"
      assert Enum.at(lines, 2) == "20150830/us-east-1/s3/aws4_request"
      assert String.length(Enum.at(lines, 3)) == 64
    end
  end
end
