defmodule Firkin.Error do
  @moduledoc """
  S3 error representation.

  Backend callbacks return `{:error, %Firkin.Error{}}` to signal errors.
  The `:code` atom is mapped to the corresponding S3 error code string and
  HTTP status by `Firkin.Error.to_http_status/1` and `Firkin.Error.to_s3_code/1`.
  """

  @type t :: %__MODULE__{
          code: error_code(),
          message: String.t() | nil,
          resource: String.t() | nil,
          request_id: String.t() | nil
        }

  @type error_code ::
          :access_denied
          | :bucket_already_exists
          | :bucket_not_empty
          | :entity_too_large
          | :internal_error
          | :invalid_argument
          | :invalid_bucket_name
          | :invalid_part
          | :invalid_part_order
          | :no_such_bucket
          | :no_such_key
          | :no_such_upload
          | :not_implemented
          | :precondition_failed
          | :not_modified
          | :signature_does_not_match

  @enforce_keys [:code]
  defstruct [:code, :message, :resource, :request_id]

  @doc """
  Returns the HTTP status code for the given error code.
  """
  @spec to_http_status(error_code()) :: pos_integer()
  def to_http_status(:not_modified), do: 304
  def to_http_status(:invalid_argument), do: 400
  def to_http_status(:invalid_bucket_name), do: 400
  def to_http_status(:entity_too_large), do: 400
  def to_http_status(:invalid_part), do: 400
  def to_http_status(:invalid_part_order), do: 400
  def to_http_status(:access_denied), do: 403
  def to_http_status(:signature_does_not_match), do: 403
  def to_http_status(:no_such_bucket), do: 404
  def to_http_status(:no_such_key), do: 404
  def to_http_status(:no_such_upload), do: 404
  def to_http_status(:bucket_already_exists), do: 409
  def to_http_status(:bucket_not_empty), do: 409
  def to_http_status(:precondition_failed), do: 412
  def to_http_status(:internal_error), do: 500
  def to_http_status(:not_implemented), do: 501

  @doc """
  Returns the S3 error code string for the given error code atom.
  """
  @spec to_s3_code(error_code()) :: String.t()
  def to_s3_code(:access_denied), do: "AccessDenied"
  def to_s3_code(:bucket_already_exists), do: "BucketAlreadyExists"
  def to_s3_code(:bucket_not_empty), do: "BucketNotEmpty"
  def to_s3_code(:entity_too_large), do: "EntityTooLarge"
  def to_s3_code(:internal_error), do: "InternalError"
  def to_s3_code(:invalid_argument), do: "InvalidArgument"
  def to_s3_code(:invalid_bucket_name), do: "InvalidBucketName"
  def to_s3_code(:invalid_part), do: "InvalidPart"
  def to_s3_code(:invalid_part_order), do: "InvalidPartOrder"
  def to_s3_code(:no_such_bucket), do: "NoSuchBucket"
  def to_s3_code(:no_such_key), do: "NoSuchKey"
  def to_s3_code(:no_such_upload), do: "NoSuchUpload"
  def to_s3_code(:not_implemented), do: "NotImplemented"
  def to_s3_code(:not_modified), do: "NotModified"
  def to_s3_code(:precondition_failed), do: "PreconditionFailed"
  def to_s3_code(:signature_does_not_match), do: "SignatureDoesNotMatch"
end
