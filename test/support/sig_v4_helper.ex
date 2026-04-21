defmodule Firkin.Test.SigV4Helper do
  @moduledoc """
  Helper for signing test requests with SigV4.
  """

  alias Firkin.Auth.SigV4

  @default_region "us-east-1"
  @default_service "s3"

  @spec sign_conn(Plug.Conn.t(), String.t(), String.t(), keyword()) :: Plug.Conn.t()
  def sign_conn(conn, access_key_id, secret_access_key, opts \\ []) do
    region = Keyword.get(opts, :region, @default_region)
    service = Keyword.get(opts, :service, @default_service)
    now = DateTime.utc_now()
    amz_date = format_amz_date(now)
    date_stamp = format_date_stamp(now)

    body = Keyword.get(opts, :body, "")
    content_sha256 = hex_sha256(body)

    conn =
      conn
      |> Plug.Conn.put_req_header("x-amz-date", amz_date)
      |> Plug.Conn.put_req_header("x-amz-content-sha256", content_sha256)
      |> ensure_host_header()

    signed_headers = ["host", "x-amz-content-sha256", "x-amz-date"]
    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

    canonical_request =
      build_canonical_request(conn, signed_headers, content_sha256)

    string_to_sign =
      SigV4.build_string_to_sign(amz_date, credential_scope, canonical_request)

    signing_key =
      SigV4.derive_signing_key(secret_access_key, date_stamp, region, service)

    signature =
      :crypto.mac(:hmac, :sha256, signing_key, string_to_sign) |> Base.encode16(case: :lower)

    auth_header =
      "AWS4-HMAC-SHA256 Credential=#{access_key_id}/#{credential_scope}, " <>
        "SignedHeaders=#{Enum.join(signed_headers, ";")}, " <>
        "Signature=#{signature}"

    Plug.Conn.put_req_header(conn, "authorization", auth_header)
  end

  defp build_canonical_request(conn, signed_headers, content_sha256) do
    SigV4.build_canonical_request(conn, signed_headers, content_sha256)
  end

  defp ensure_host_header(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [] -> Plug.Conn.put_req_header(conn, "host", "localhost")
      _ -> conn
    end
  end

  defp format_amz_date(dt) do
    Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  end

  defp format_date_stamp(dt) do
    Calendar.strftime(dt, "%Y%m%d")
  end

  defp hex_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
