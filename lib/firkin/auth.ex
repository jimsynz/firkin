defmodule Firkin.Auth do
  @moduledoc """
  S3 Signature Version 4 authentication.

  Supports both the Authorization header and presigned URL query parameters.
  """

  alias Firkin.Auth.SigV4

  @type auth_result ::
          {:ok, Firkin.Backend.auth_context()}
          | {:error, :invalid_signature | :credential_not_found | :expired}

  @doc """
  Authenticates an incoming request using the backend's credential lookup.

  Tries the Authorization header first, then falls back to presigned URL
  query parameters.
  """
  @spec authenticate(Plug.Conn.t(), module()) :: auth_result()
  def authenticate(conn, backend) do
    cond do
      auth_header?(conn) -> authenticate_header(conn, backend)
      presigned?(conn) -> authenticate_presigned(conn, backend)
      true -> {:error, :invalid_signature}
    end
  end

  defp auth_header?(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [<<"AWS4-HMAC-SHA256 " <> _>> | _] -> true
      _ -> false
    end
  end

  defp presigned?(conn) do
    conn.query_string
    |> URI.decode_query()
    |> Map.has_key?("X-Amz-Algorithm")
  end

  defp authenticate_header(conn, backend) do
    [auth_header] = Plug.Conn.get_req_header(conn, "authorization")

    with {:ok, parsed} <- SigV4.parse_auth_header(auth_header),
         {:ok, credential} <- backend.lookup_credential(parsed.access_key_id),
         :ok <- SigV4.verify_header_signature(conn, parsed, credential) do
      {:ok, %{access_key_id: credential.access_key_id, identity: credential.identity}}
    else
      {:error, :not_found} -> {:error, :credential_not_found}
      other -> other
    end
  end

  defp authenticate_presigned(conn, backend) do
    params = URI.decode_query(conn.query_string)

    with {:ok, parsed} <- SigV4.parse_presigned_params(params),
         {:ok, credential} <- backend.lookup_credential(parsed.access_key_id),
         :ok <- SigV4.verify_presigned_signature(conn, parsed, credential) do
      {:ok, %{access_key_id: credential.access_key_id, identity: credential.identity}}
    else
      {:error, :not_found} -> {:error, :credential_not_found}
      other -> other
    end
  end
end
