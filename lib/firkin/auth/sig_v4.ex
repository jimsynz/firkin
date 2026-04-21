defmodule Firkin.Auth.SigV4 do
  @moduledoc """
  AWS Signature Version 4 implementation for server-side verification.
  """

  require Logger

  @type parsed_header :: %{
          access_key_id: String.t(),
          credential_scope: String.t(),
          signed_headers: [String.t()],
          signature: String.t(),
          date: String.t(),
          region: String.t(),
          service: String.t()
        }

  @type parsed_presigned :: %{
          access_key_id: String.t(),
          credential_scope: String.t(),
          signed_headers: [String.t()],
          signature: String.t(),
          date: String.t(),
          region: String.t(),
          service: String.t(),
          expires: non_neg_integer(),
          amz_date: String.t()
        }

  @doc """
  Parses an AWS4-HMAC-SHA256 Authorization header.
  """
  @spec parse_auth_header(String.t()) :: {:ok, parsed_header()} | {:error, :invalid_signature}
  def parse_auth_header(<<"AWS4-HMAC-SHA256 ", rest::binary>>) do
    parts =
      rest
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {String.trim(key), String.trim(value)}
          _ -> {part, ""}
        end
      end)

    with credential when is_binary(credential) <- Map.get(parts, "Credential"),
         signed_headers_str when is_binary(signed_headers_str) <-
           Map.get(parts, "SignedHeaders"),
         signature when is_binary(signature) <- Map.get(parts, "Signature"),
         [access_key_id, date, region, service, "aws4_request"] <-
           String.split(credential, "/") do
      {:ok,
       %{
         access_key_id: access_key_id,
         credential_scope: "#{date}/#{region}/#{service}/aws4_request",
         signed_headers: String.split(signed_headers_str, ";"),
         signature: signature,
         date: date,
         region: region,
         service: service
       }}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def parse_auth_header(_), do: {:error, :invalid_signature}

  @doc """
  Parses presigned URL query parameters.
  """
  @spec parse_presigned_params(map()) :: {:ok, parsed_presigned()} | {:error, :invalid_signature}
  def parse_presigned_params(params) do
    with "AWS4-HMAC-SHA256" <- Map.get(params, "X-Amz-Algorithm"),
         credential when is_binary(credential) <- Map.get(params, "X-Amz-Credential"),
         signed_headers_str when is_binary(signed_headers_str) <-
           Map.get(params, "X-Amz-SignedHeaders"),
         signature when is_binary(signature) <- Map.get(params, "X-Amz-Signature"),
         amz_date when is_binary(amz_date) <- Map.get(params, "X-Amz-Date"),
         expires_str when is_binary(expires_str) <- Map.get(params, "X-Amz-Expires"),
         {expires, ""} <- Integer.parse(expires_str),
         [access_key_id, date, region, service, "aws4_request"] <-
           String.split(credential, "/") do
      {:ok,
       %{
         access_key_id: access_key_id,
         credential_scope: "#{date}/#{region}/#{service}/aws4_request",
         signed_headers: String.split(signed_headers_str, ";"),
         signature: signature,
         date: date,
         region: region,
         service: service,
         expires: expires,
         amz_date: amz_date
       }}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @doc """
  Verifies the signature from an Authorization header.
  """
  @spec verify_header_signature(Plug.Conn.t(), parsed_header(), Firkin.Credential.t()) ::
          :ok | {:error, :invalid_signature | :credential_not_found}
  def verify_header_signature(conn, parsed, credential) do
    amz_date = get_amz_date(conn)
    content_sha256 = get_content_sha256(conn)

    canonical_request =
      build_canonical_request(conn, parsed.signed_headers, content_sha256)

    string_to_sign = build_string_to_sign(amz_date, parsed.credential_scope, canonical_request)

    signing_key =
      derive_signing_key(
        credential.secret_access_key,
        parsed.date,
        parsed.region,
        parsed.service
      )

    expected_signature = hex_hmac_sha256(signing_key, string_to_sign)

    if secure_compare(expected_signature, parsed.signature) do
      :ok
    else
      log_mismatch(:header, conn, parsed, canonical_request, string_to_sign, expected_signature)
      {:error, :invalid_signature}
    end
  end

  @doc """
  Verifies a presigned URL signature.
  """
  @spec verify_presigned_signature(Plug.Conn.t(), parsed_presigned(), Firkin.Credential.t()) ::
          :ok | {:error, :invalid_signature | :expired | :credential_not_found}
  def verify_presigned_signature(conn, parsed, credential) do
    with :ok <- check_expiry(parsed.amz_date, parsed.expires) do
      canonical_request =
        build_presigned_canonical_request(conn, parsed.signed_headers, parsed.signature)

      string_to_sign =
        build_string_to_sign(parsed.amz_date, parsed.credential_scope, canonical_request)

      signing_key =
        derive_signing_key(
          credential.secret_access_key,
          parsed.date,
          parsed.region,
          parsed.service
        )

      expected_signature = hex_hmac_sha256(signing_key, string_to_sign)

      if secure_compare(expected_signature, parsed.signature) do
        :ok
      else
        log_mismatch(
          :presigned,
          conn,
          parsed,
          canonical_request,
          string_to_sign,
          expected_signature
        )

        {:error, :invalid_signature}
      end
    end
  end

  @doc """
  Builds a canonical request string per the SigV4 spec.
  """
  @spec build_canonical_request(Plug.Conn.t(), [String.t()], String.t()) :: String.t()
  def build_canonical_request(conn, signed_headers, content_sha256) do
    canonical_headers = build_canonical_headers(conn, signed_headers)
    canonical_query = build_canonical_query_string(conn.query_string)

    [
      String.upcase(conn.method),
      canonical_uri(conn),
      canonical_query,
      canonical_headers,
      "",
      Enum.join(signed_headers, ";"),
      content_sha256
    ]
    |> Enum.join("\n")
  end

  @doc """
  Signs a string with the given secret key using the SigV4 key derivation.
  """
  @spec derive_signing_key(String.t(), String.t(), String.t(), String.t()) :: binary()
  def derive_signing_key(secret_access_key, date, region, service) do
    ("AWS4" <> secret_access_key)
    |> hmac_sha256(date)
    |> hmac_sha256(region)
    |> hmac_sha256(service)
    |> hmac_sha256("aws4_request")
  end

  @doc """
  Builds a string to sign per the SigV4 spec.
  """
  @spec build_string_to_sign(String.t(), String.t(), String.t()) :: String.t()
  def build_string_to_sign(amz_date, credential_scope, canonical_request) do
    [
      "AWS4-HMAC-SHA256",
      amz_date,
      credential_scope,
      hex_sha256(canonical_request)
    ]
    |> Enum.join("\n")
  end

  defp build_presigned_canonical_request(conn, signed_headers, _signature) do
    canonical_headers = build_canonical_headers(conn, signed_headers)

    query_params =
      conn.query_string
      |> URI.decode_query()
      |> Map.delete("X-Amz-Signature")

    canonical_query =
      query_params
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{uri_encode(k)}=#{uri_encode(v)}" end)

    [
      String.upcase(conn.method),
      canonical_uri(conn),
      canonical_query,
      canonical_headers,
      "",
      Enum.join(signed_headers, ";"),
      "UNSIGNED-PAYLOAD"
    ]
    |> Enum.join("\n")
  end

  defp canonical_uri(conn) do
    # SigV4 canonical URI is the on-wire (already-URI-encoded) path.
    # Bandit exposes conn.request_path in that form; re-encoding it here
    # would double-encode percent escapes (e.g. %20 → %2520).
    conn.request_path || "/"
  end

  defp build_canonical_query_string(""), do: ""
  defp build_canonical_query_string(nil), do: ""

  defp build_canonical_query_string(query_string) do
    query_string
    |> URI.decode_query()
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{uri_encode(k)}=#{uri_encode(v)}" end)
  end

  defp build_canonical_headers(conn, signed_headers) do
    Enum.map_join(signed_headers, "\n", fn header ->
      values =
        conn
        |> Plug.Conn.get_req_header(header)
        |> Enum.map_join(",", &String.trim/1)

      "#{header}:#{values}"
    end)
  end

  defp get_amz_date(conn) do
    case Plug.Conn.get_req_header(conn, "x-amz-date") do
      [date | _] -> date
      [] -> Plug.Conn.get_req_header(conn, "date") |> List.first("")
    end
  end

  defp get_content_sha256(conn) do
    case Plug.Conn.get_req_header(conn, "x-amz-content-sha256") do
      [sha | _] -> sha
      [] -> "UNSIGNED-PAYLOAD"
    end
  end

  defp check_expiry(amz_date, expires_seconds) do
    with {:ok, request_time} <- parse_amz_date(amz_date) do
      expiry_time = DateTime.add(request_time, expires_seconds, :second)

      if DateTime.compare(DateTime.utc_now(), expiry_time) == :lt do
        :ok
      else
        {:error, :expired}
      end
    end
  end

  defp parse_amz_date(
         <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           min::binary-size(2), s::binary-size(2), "Z">>
       ) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(min),
         {second, ""} <- Integer.parse(s) do
      DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second))
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp parse_amz_date(_), do: {:error, :invalid_signature}

  defp log_mismatch(kind, conn, parsed, canonical_request, string_to_sign, expected_signature) do
    headers_dump =
      conn.req_headers
      |> Enum.map_join("\n", fn {k, v} -> "  #{k}: #{v}" end)

    Logger.debug("""
    Firkin SigV4 mismatch (#{kind})
    method: #{conn.method}
    request_path: #{inspect(conn.request_path)}
    query_string: #{inspect(conn.query_string)}
    access_key_id: #{parsed.access_key_id}
    signed_headers: #{Enum.join(parsed.signed_headers, ";")}
    client_signature:   #{parsed.signature}
    expected_signature: #{expected_signature}

    Canonical request:
    #{canonical_request}

    String to sign:
    #{string_to_sign}

    Request headers:
    #{headers_dump}
    """)
  end

  defp hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex_hmac_sha256(key, data), do: Base.encode16(hmac_sha256(key, data), case: :lower)

  defp hex_sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp uri_encode(value) do
    value
    |> to_string()
    |> URI.encode(&uri_unreserved?/1)
  end

  defp uri_unreserved?(char) do
    char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?-, ?., ?_, ?~]
  end

  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false

  defp secure_compare(a, b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    Enum.zip(a_bytes, b_bytes)
    |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end
end
