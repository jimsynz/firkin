defmodule Firkin.Backend do
  @moduledoc """
  Behaviour for S3 storage backends.

  Implement this behaviour to provide actual storage operations behind the
  S3-compatible HTTP interface. All callbacks receive an auth context map
  containing the authenticated identity from `lookup_credential/1`.

  Multipart upload callbacks are optional — the server returns 501 Not
  Implemented for multipart operations if they are not defined.
  """

  @type auth_context :: %{
          access_key_id: String.t(),
          identity: term()
        }

  @type bucket :: String.t()
  @type key :: String.t()
  @type s3_error :: Firkin.Error.t()

  @callback lookup_credential(access_key_id :: String.t()) ::
              {:ok, Firkin.Credential.t()} | {:error, :not_found}

  @callback list_buckets(auth_context()) ::
              {:ok, [Firkin.Bucket.t()]} | {:error, s3_error()}

  @callback create_bucket(auth_context(), bucket()) ::
              :ok | {:error, s3_error()}

  @callback delete_bucket(auth_context(), bucket()) ::
              :ok | {:error, s3_error()}

  @callback head_bucket(auth_context(), bucket()) ::
              :ok | {:error, s3_error()}

  @callback get_bucket_location(auth_context(), bucket()) ::
              {:ok, String.t()} | {:error, s3_error()}

  @callback get_object(auth_context(), bucket(), key(), Firkin.GetOpts.t()) ::
              {:ok, Firkin.Object.t()} | {:error, s3_error()}

  @callback put_object(auth_context(), bucket(), key(), body :: iodata(), Firkin.PutOpts.t()) ::
              {:ok, etag :: String.t()} | {:error, s3_error()}

  # Streaming PutObject (optional). When implemented the Plug routes
  # request bodies through this callback instead of `put_object/5` so
  # multi-GB uploads are not buffered in memory.
  @callback put_object_stream(
              auth_context(),
              bucket(),
              key(),
              body :: Enumerable.t(),
              Firkin.PutOpts.t()
            ) ::
              {:ok, etag :: String.t()} | {:error, s3_error()}

  @callback delete_object(auth_context(), bucket(), key()) ::
              :ok | {:error, s3_error()}

  @callback delete_objects(auth_context(), bucket(), [key()]) ::
              {:ok, Firkin.DeleteResult.t()} | {:error, s3_error()}

  @callback head_object(auth_context(), bucket(), key()) ::
              {:ok, Firkin.ObjectMeta.t()} | {:error, s3_error()}

  @callback list_objects_v2(auth_context(), bucket(), Firkin.ListOpts.t()) ::
              {:ok, Firkin.ListResult.t()} | {:error, s3_error()}

  @callback copy_object(
              auth_context(),
              bucket(),
              key(),
              source_bucket :: bucket(),
              source_key :: key()
            ) ::
              {:ok, Firkin.CopyResult.t()} | {:error, s3_error()}

  @callback create_multipart_upload(auth_context(), bucket(), key(), opts :: map()) ::
              {:ok, upload_id :: String.t()} | {:error, s3_error()}

  @callback upload_part(
              auth_context(),
              bucket(),
              key(),
              upload_id :: String.t(),
              part_number :: pos_integer(),
              body :: iodata()
            ) ::
              {:ok, etag :: String.t()} | {:error, s3_error()}

  # Streaming UploadPart (optional). Same rationale as `put_object_stream/5`
  # — S3 parts can be up to 5 GiB and must not be buffered in memory.
  @callback upload_part_stream(
              auth_context(),
              bucket(),
              key(),
              upload_id :: String.t(),
              part_number :: pos_integer(),
              body :: Enumerable.t()
            ) ::
              {:ok, etag :: String.t()} | {:error, s3_error()}

  @callback complete_multipart_upload(
              auth_context(),
              bucket(),
              key(),
              upload_id :: String.t(),
              parts :: [{pos_integer(), String.t()}]
            ) ::
              {:ok, Firkin.CompleteResult.t()} | {:error, s3_error()}

  @callback abort_multipart_upload(auth_context(), bucket(), key(), upload_id :: String.t()) ::
              :ok | {:error, s3_error()}

  @callback list_multipart_uploads(auth_context(), bucket(), opts :: map()) ::
              {:ok, Firkin.MultipartList.t()} | {:error, s3_error()}

  @callback list_parts(auth_context(), bucket(), key(), upload_id :: String.t(), opts :: map()) ::
              {:ok, Firkin.PartList.t()} | {:error, s3_error()}

  @optional_callbacks [
    create_multipart_upload: 4,
    upload_part: 6,
    upload_part_stream: 6,
    complete_multipart_upload: 5,
    abort_multipart_upload: 4,
    list_multipart_uploads: 3,
    list_parts: 5,
    put_object_stream: 5
  ]
end
