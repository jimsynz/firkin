defmodule Firkin.XML do
  @moduledoc """
  XML generation and parsing for S3 protocol messages.

  Uses Saxy for both generation (simple form builder) and parsing
  (SAX event-based parsing for request bodies).
  """

  @s3_xmlns "http://s3.amazonaws.com/doc/2006-03-01/"

  @doc """
  Generates the ListAllMyBucketsResult XML response.
  """
  @spec list_buckets_response([Firkin.Bucket.t()]) :: String.t()
  def list_buckets_response(buckets) do
    bucket_elements =
      Enum.map(buckets, fn bucket ->
        {"Bucket", [],
         [
           {"Name", [], [bucket.name]},
           {"CreationDate", [], [format_datetime(bucket.creation_date)]}
         ]}
      end)

    build_xml(
      {"ListAllMyBucketsResult", [{"xmlns", @s3_xmlns}],
       [
         {"Owner", [], [{"ID", [], [""]}, {"DisplayName", [], [""]}]},
         {"Buckets", [], bucket_elements}
       ]}
    )
  end

  @doc """
  Generates the LocationConstraint XML response.
  """
  @spec get_bucket_location_response(String.t()) :: String.t()
  def get_bucket_location_response(location) do
    build_xml({"LocationConstraint", [{"xmlns", @s3_xmlns}], [location]})
  end

  @doc """
  Generates the ListBucketResult (V2) XML response.
  """
  @spec list_objects_v2_response(Firkin.ListResult.t()) :: String.t()
  def list_objects_v2_response(result) do
    contents =
      Enum.map(result.contents, fn meta ->
        {"Contents", [],
         [
           {"Key", [], [meta.key]},
           {"LastModified", [], [format_datetime(meta.last_modified)]},
           {"ETag", [], [ensure_quoted(meta.etag)]},
           {"Size", [], [to_string(meta.size)]},
           {"StorageClass", [], [meta.storage_class || "STANDARD"]}
         ]}
      end)

    prefixes =
      Enum.map(result.common_prefixes, fn prefix ->
        {"CommonPrefixes", [], [{"Prefix", [], [prefix]}]}
      end)

    children =
      [
        {"Name", [], [result.name]},
        {"Prefix", [], [result.prefix || ""]},
        {"KeyCount", [], [to_string(result.key_count)]},
        {"MaxKeys", [], [to_string(result.max_keys)]},
        {"IsTruncated", [], [to_string(result.is_truncated)]}
      ] ++
        optional("Delimiter", result.delimiter) ++
        optional("ContinuationToken", result.continuation_token) ++
        optional("NextContinuationToken", result.next_continuation_token) ++
        contents ++
        prefixes

    build_xml({"ListBucketResult", [{"xmlns", @s3_xmlns}], children})
  end

  @doc """
  Generates the CopyObjectResult XML response.
  """
  @spec copy_object_response(Firkin.CopyResult.t()) :: String.t()
  def copy_object_response(result) do
    build_xml(
      {"CopyObjectResult", [{"xmlns", @s3_xmlns}],
       [
         {"ETag", [], [ensure_quoted(result.etag)]},
         {"LastModified", [], [format_datetime(result.last_modified)]}
       ]}
    )
  end

  @doc """
  Generates the DeleteResult XML response.
  """
  @spec delete_objects_response(Firkin.DeleteResult.t()) :: String.t()
  def delete_objects_response(result) do
    deleted =
      Enum.map(result.deleted, fn entry ->
        {"Deleted", [], [{"Key", [], [entry.key]}]}
      end)

    errors =
      Enum.map(result.errors, fn entry ->
        {"Error", [],
         [
           {"Key", [], [entry.key]},
           {"Code", [], [entry.code]},
           {"Message", [], [entry.message]}
         ]}
      end)

    build_xml({"DeleteResult", [{"xmlns", @s3_xmlns}], deleted ++ errors})
  end

  @doc """
  Generates the InitiateMultipartUploadResult XML response.
  """
  @spec initiate_multipart_upload_response(String.t(), String.t(), String.t()) :: String.t()
  def initiate_multipart_upload_response(bucket, key, upload_id) do
    build_xml(
      {"InitiateMultipartUploadResult", [{"xmlns", @s3_xmlns}],
       [
         {"Bucket", [], [bucket]},
         {"Key", [], [key]},
         {"UploadId", [], [upload_id]}
       ]}
    )
  end

  @doc """
  Generates the CompleteMultipartUploadResult XML response.
  """
  @spec complete_multipart_upload_response(Firkin.CompleteResult.t()) :: String.t()
  def complete_multipart_upload_response(result) do
    build_xml(
      {"CompleteMultipartUploadResult", [{"xmlns", @s3_xmlns}],
       [
         {"Location", [], [result.location]},
         {"Bucket", [], [result.bucket]},
         {"Key", [], [result.key]},
         {"ETag", [], [ensure_quoted(result.etag)]}
       ]}
    )
  end

  @doc """
  Generates the ListMultipartUploadsResult XML response.
  """
  @spec list_multipart_uploads_response(Firkin.MultipartList.t()) :: String.t()
  def list_multipart_uploads_response(result) do
    uploads =
      Enum.map(result.uploads, fn upload ->
        {"Upload", [],
         [
           {"Key", [], [upload.key]},
           {"UploadId", [], [upload.upload_id]},
           {"Initiated", [], [format_datetime(upload.initiated)]}
         ]}
      end)

    build_xml(
      {"ListMultipartUploadsResult", [{"xmlns", @s3_xmlns}],
       [
         {"Bucket", [], [result.bucket]},
         {"MaxUploads", [], [to_string(result.max_uploads)]},
         {"IsTruncated", [], [to_string(result.is_truncated)]}
       ] ++ uploads}
    )
  end

  @doc """
  Generates the ListPartsResult XML response.
  """
  @spec list_parts_response(Firkin.PartList.t()) :: String.t()
  def list_parts_response(result) do
    parts =
      Enum.map(result.parts, fn part ->
        {"Part", [],
         [
           {"PartNumber", [], [to_string(part.part_number)]},
           {"ETag", [], [ensure_quoted(part.etag)]},
           {"Size", [], [to_string(part.size)]},
           {"LastModified", [], [format_datetime(part.last_modified)]}
         ]}
      end)

    build_xml(
      {"ListPartsResult", [{"xmlns", @s3_xmlns}],
       [
         {"Bucket", [], [result.bucket]},
         {"Key", [], [result.key]},
         {"UploadId", [], [result.upload_id]},
         {"MaxParts", [], [to_string(result.max_parts)]},
         {"IsTruncated", [], [to_string(result.is_truncated)]}
       ] ++ parts}
    )
  end

  @doc """
  Generates an S3 error XML response.
  """
  @spec error_response(Firkin.Error.t()) :: String.t()
  def error_response(error) do
    children =
      [
        {"Code", [], [Firkin.Error.to_s3_code(error.code)]},
        {"Message", [], [error.message || default_message(error.code)]}
      ] ++
        optional("Resource", error.resource) ++
        optional("RequestId", error.request_id)

    build_xml({"Error", [], children})
  end

  @doc """
  Parses a DeleteObjects XML request body, extracting the list of keys.
  """
  @spec parse_delete_objects(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_xml}
  def parse_delete_objects(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, {"Delete", _attrs, children}} ->
        keys =
          children
          |> Enum.filter(fn
            {"Object", _, _} -> true
            _ -> false
          end)
          |> Enum.flat_map(fn {"Object", _, obj_children} ->
            Enum.flat_map(obj_children, fn
              {"Key", _, [key]} -> [key]
              _ -> []
            end)
          end)

        {:ok, keys}

      _ ->
        {:error, :invalid_xml}
    end
  end

  @doc """
  Parses a CompleteMultipartUpload XML request body, extracting parts.
  """
  @spec parse_complete_multipart(String.t()) ::
          {:ok, [{pos_integer(), String.t()}]} | {:error, :invalid_xml}
  def parse_complete_multipart(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, {"CompleteMultipartUpload", _attrs, children}} ->
        parts =
          children
          |> Enum.filter(&match?({"Part", _, _}, &1))
          |> Enum.map(&parse_part_element/1)

        {:ok, parts}

      _ ->
        {:error, :invalid_xml}
    end
  end

  defp parse_part_element({"Part", _, part_children}) do
    part_map =
      part_children
      |> Enum.filter(&match?({_, _, _}, &1))
      |> Map.new(fn
        {name, _, [value]} -> {name, value}
        {name, _, _} -> {name, ""}
      end)

    {String.to_integer(Map.get(part_map, "PartNumber", "0")),
     String.trim(Map.get(part_map, "ETag", ""), "\"")}
  end

  defp build_xml(element) do
    iodata = Saxy.encode_to_iodata!(element)
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <> IO.iodata_to_binary(iodata)
  end

  defp optional(_name, nil), do: []
  defp optional(name, value), do: [{name, [], [value]}]

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)

  defp ensure_quoted(etag) do
    if String.starts_with?(etag, "\""), do: etag, else: "\"#{etag}\""
  end

  defp default_message(:access_denied), do: "Access Denied"
  defp default_message(:bucket_already_exists), do: "Bucket already exists"
  defp default_message(:bucket_not_empty), do: "The bucket you tried to delete is not empty"
  defp default_message(:entity_too_large), do: "Your proposed upload exceeds the maximum size"
  defp default_message(:internal_error), do: "Internal server error"
  defp default_message(:invalid_argument), do: "Invalid argument"
  defp default_message(:invalid_bucket_name), do: "The specified bucket is not valid"
  defp default_message(:invalid_part), do: "One or more of the specified parts could not be found"
  defp default_message(:invalid_part_order), do: "The list of parts was not in ascending order"
  defp default_message(:no_such_bucket), do: "The specified bucket does not exist"
  defp default_message(:no_such_key), do: "The specified key does not exist"
  defp default_message(:no_such_upload), do: "The specified upload does not exist"
  defp default_message(:not_implemented), do: "This operation is not implemented"
  defp default_message(:not_modified), do: "Not Modified"
  defp default_message(:precondition_failed), do: "Precondition Failed"

  defp default_message(:signature_does_not_match),
    do: "The request signature we calculated does not match the signature you provided"
end
