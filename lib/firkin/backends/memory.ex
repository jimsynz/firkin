defmodule Firkin.Backends.Memory do
  @moduledoc """
  Reference implementation of `Firkin.Backend` — stores credentials,
  buckets, objects, and multipart uploads in a named ETS table.

  This module exists for three purposes:

    1. **Reference** — every callback in `Firkin.Backend` has a working
       implementation here. Read the source if you're unsure how your
       own backend should shape its return values (`Firkin.Object`,
       `Firkin.ListResult`, `Firkin.DeleteResult`, etc.).

    2. **Manual testing** — the default backend for `mix firkin.serve`,
       letting you drive Firkin from `aws` CLI / `mc` / any S3 client
       without writing a storage layer first.

    3. **Test double** — downstream projects using Firkin-compatible
       tooling can point their tests at this backend instead of
       standing up MinIO.

  **Not for production use.** All state lives in a single ETS table and
  disappears when the owning BEAM process exits. No concurrency controls
  beyond ETS atomicity. No persistence. No quotas. No pagination for
  `ListObjectsV2`, `ListMultipartUploads`, or `ListParts`.

  ## Usage

      Firkin.Backends.Memory.start()
      Firkin.Backends.Memory.add_credential("AKID", "SECRET")

      forward "/s3", Firkin.Plug,
        backend: Firkin.Backends.Memory,
        region: "us-east-1"

  Implements the streaming variants of `put_object_stream/5` and
  `upload_part_stream/6`, so the Plug's `:max_buffered_put_bytes` cap
  is bypassed when this backend is used.
  """
  @behaviour Firkin.Backend

  @table __MODULE__

  @doc """
  Creates the ETS table if it does not exist and resets all state.
  """
  @spec start :: :ok
  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    reset()
  end

  @doc """
  Clears all stored state. Leaves the ETS table in place.
  """
  @spec reset :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:credentials, %{}})
    :ets.insert(@table, {:buckets, %{}})
    :ets.insert(@table, {:objects, %{}})
    :ets.insert(@table, {:uploads, %{}})
    :ok
  end

  @doc """
  Registers an access-key/secret-key credential pair. The identity
  stored alongside is `%{user: access_key_id}` — adequate for demos.
  """
  @spec add_credential(String.t(), String.t()) :: :ok
  def add_credential(access_key_id, secret_access_key) do
    [{:credentials, creds}] = :ets.lookup(@table, :credentials)

    :ets.insert(
      @table,
      {:credentials,
       Map.put(creds, access_key_id, %Firkin.Credential{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         identity: %{user: access_key_id}
       })}
    )

    :ok
  end

  @impl true
  def lookup_credential(access_key_id) do
    [{:credentials, creds}] = :ets.lookup(@table, :credentials)

    case Map.get(creds, access_key_id) do
      nil -> {:error, :not_found}
      cred -> {:ok, cred}
    end
  end

  @impl true
  def list_buckets(_ctx) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)

    bucket_list =
      buckets
      |> Enum.map(fn {name, created_at} ->
        %Firkin.Bucket{name: name, creation_date: created_at}
      end)
      |> Enum.sort_by(& &1.name)

    {:ok, bucket_list}
  end

  @impl true
  def create_bucket(_ctx, bucket) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)

    if Map.has_key?(buckets, bucket) do
      {:error, %Firkin.Error{code: :bucket_already_exists}}
    else
      :ets.insert(@table, {:buckets, Map.put(buckets, bucket, DateTime.utc_now())})
      :ok
    end
  end

  @impl true
  def delete_bucket(_ctx, bucket) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    cond do
      not Map.has_key?(buckets, bucket) ->
        {:error, %Firkin.Error{code: :no_such_bucket}}

      Enum.any?(objects, fn {{b, _}, _} -> b == bucket end) ->
        {:error, %Firkin.Error{code: :bucket_not_empty}}

      true ->
        :ets.insert(@table, {:buckets, Map.delete(buckets, bucket)})
        :ok
    end
  end

  @impl true
  def head_bucket(_ctx, bucket) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)

    if Map.has_key?(buckets, bucket) do
      :ok
    else
      {:error, %Firkin.Error{code: :no_such_bucket}}
    end
  end

  @impl true
  def get_bucket_location(_ctx, bucket) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)

    if Map.has_key?(buckets, bucket) do
      {:ok, "us-east-1"}
    else
      {:error, %Firkin.Error{code: :no_such_bucket}}
    end
  end

  @impl true
  def put_object(_ctx, bucket, key, body, opts) do
    do_put_object(bucket, key, IO.iodata_to_binary(body), opts)
  end

  @impl true
  def put_object_stream(_ctx, bucket, key, body, opts) do
    body_binary = body |> Enum.to_list() |> IO.iodata_to_binary()
    do_put_object(bucket, key, body_binary, opts)
  end

  defp do_put_object(bucket, key, body_binary, opts) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    if Map.has_key?(buckets, bucket) do
      etag = :crypto.hash(:md5, body_binary) |> Base.encode16(case: :lower)

      object = %{
        body: body_binary,
        content_type: opts.content_type,
        size: byte_size(body_binary),
        etag: etag,
        last_modified: DateTime.utc_now(),
        metadata: opts.metadata
      }

      :ets.insert(@table, {:objects, Map.put(objects, {bucket, key}, object)})
      {:ok, etag}
    else
      {:error, %Firkin.Error{code: :no_such_bucket}}
    end
  end

  @impl true
  def get_object(_ctx, bucket, key, opts) do
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    case Map.get(objects, {bucket, key}) do
      nil ->
        {:error, %Firkin.Error{code: :no_such_key}}

      obj ->
        {body, content_length} = apply_range(obj.body, opts.range)

        {:ok,
         %Firkin.Object{
           body: body,
           content_type: obj.content_type,
           content_length: content_length,
           total_size: obj.size,
           etag: obj.etag,
           last_modified: obj.last_modified,
           metadata: obj.metadata
         }}
    end
  end

  defp apply_range(body, nil), do: {body, byte_size(body)}

  defp apply_range(body, {start_byte, end_byte}) do
    clamped_end = min(end_byte, byte_size(body) - 1)
    length = clamped_end - start_byte + 1
    {binary_part(body, start_byte, length), length}
  end

  @impl true
  def head_object(_ctx, bucket, key) do
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    case Map.get(objects, {bucket, key}) do
      nil ->
        {:error, %Firkin.Error{code: :no_such_key}}

      obj ->
        {:ok,
         %Firkin.ObjectMeta{
           key: key,
           etag: obj.etag,
           size: obj.size,
           last_modified: obj.last_modified,
           content_type: obj.content_type,
           metadata: obj.metadata
         }}
    end
  end

  @impl true
  def delete_object(_ctx, bucket, key) do
    [{:objects, objects}] = :ets.lookup(@table, :objects)
    :ets.insert(@table, {:objects, Map.delete(objects, {bucket, key})})
    :ok
  end

  @impl true
  def delete_objects(_ctx, _bucket, keys) do
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    deleted =
      Enum.map(keys, fn key ->
        %{key: key}
      end)

    new_objects =
      Enum.reduce(keys, objects, fn key, acc ->
        Enum.reduce(acc, %{}, fn
          {{_b, ^key}, _v}, inner_acc -> inner_acc
          {k, v}, inner_acc -> Map.put(inner_acc, k, v)
        end)
      end)

    :ets.insert(@table, {:objects, new_objects})
    {:ok, %Firkin.DeleteResult{deleted: deleted, errors: []}}
  end

  @impl true
  def list_objects_v2(_ctx, bucket, opts) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)

    if Map.has_key?(buckets, bucket) do
      do_list_objects_v2(bucket, opts)
    else
      {:error, %Firkin.Error{code: :no_such_bucket}}
    end
  end

  defp do_list_objects_v2(bucket, opts) do
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    all_keys =
      objects
      |> Enum.filter(fn {{b, _}, _} -> b == bucket end)
      |> Enum.map(fn {{_, k}, obj} ->
        %Firkin.ObjectMeta{
          key: k,
          etag: obj.etag,
          size: obj.size,
          last_modified: obj.last_modified,
          content_type: obj.content_type,
          metadata: obj.metadata
        }
      end)
      |> Enum.filter(fn meta ->
        if opts.prefix, do: String.starts_with?(meta.key, opts.prefix), else: true
      end)
      |> Enum.sort_by(& &1.key)

    {contents, common_prefixes} = split_by_delimiter(all_keys, opts)
    truncated = length(contents) > opts.max_keys
    contents = Enum.take(contents, opts.max_keys)

    {:ok,
     %Firkin.ListResult{
       name: bucket,
       prefix: opts.prefix,
       delimiter: opts.delimiter,
       contents: contents,
       common_prefixes: common_prefixes,
       key_count: length(contents),
       max_keys: opts.max_keys,
       is_truncated: truncated
     }}
  end

  defp split_by_delimiter(all_keys, %{delimiter: nil}), do: {all_keys, []}

  defp split_by_delimiter(all_keys, opts) do
    prefix_len = String.length(opts.prefix || "")

    {regular, prefixed} =
      Enum.split_with(all_keys, fn meta ->
        rest = String.slice(meta.key, prefix_len..-1//1)
        not String.contains?(rest, opts.delimiter)
      end)

    prefix_set =
      prefixed
      |> Enum.map(fn meta ->
        rest = String.slice(meta.key, prefix_len..-1//1)
        idx = :binary.match(rest, opts.delimiter) |> elem(0)
        (opts.prefix || "") <> String.slice(rest, 0, idx + 1)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {regular, prefix_set}
  end

  @impl true
  def copy_object(_ctx, bucket, key, source_bucket, source_key) do
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    case Map.get(objects, {source_bucket, source_key}) do
      nil ->
        {:error, %Firkin.Error{code: :no_such_key}}

      source_obj ->
        now = DateTime.utc_now()
        new_obj = %{source_obj | last_modified: now}
        :ets.insert(@table, {:objects, Map.put(objects, {bucket, key}, new_obj)})

        {:ok,
         %Firkin.CopyResult{
           etag: source_obj.etag,
           last_modified: now
         }}
    end
  end

  @impl true
  def create_multipart_upload(_ctx, bucket, key, _opts) do
    [{:uploads, uploads}] = :ets.lookup(@table, :uploads)
    upload_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    upload = %{
      bucket: bucket,
      key: key,
      parts: %{},
      initiated: DateTime.utc_now()
    }

    :ets.insert(@table, {:uploads, Map.put(uploads, upload_id, upload)})
    {:ok, upload_id}
  end

  @impl true
  def upload_part(_ctx, _bucket, _key, upload_id, part_number, body) do
    do_upload_part(upload_id, part_number, IO.iodata_to_binary(body))
  end

  @impl true
  def upload_part_stream(_ctx, _bucket, _key, upload_id, part_number, body) do
    body_binary = body |> Enum.to_list() |> IO.iodata_to_binary()
    do_upload_part(upload_id, part_number, body_binary)
  end

  defp do_upload_part(upload_id, part_number, body_binary) do
    [{:uploads, uploads}] = :ets.lookup(@table, :uploads)

    case Map.get(uploads, upload_id) do
      nil ->
        {:error, %Firkin.Error{code: :no_such_upload}}

      upload ->
        etag = :crypto.hash(:md5, body_binary) |> Base.encode16(case: :lower)

        part = %{body: body_binary, etag: etag, size: byte_size(body_binary)}
        updated = %{upload | parts: Map.put(upload.parts, part_number, part)}
        :ets.insert(@table, {:uploads, Map.put(uploads, upload_id, updated)})
        {:ok, etag}
    end
  end

  @impl true
  def complete_multipart_upload(_ctx, bucket, key, upload_id, _parts) do
    [{:uploads, uploads}] = :ets.lookup(@table, :uploads)
    [{:objects, objects}] = :ets.lookup(@table, :objects)

    case Map.get(uploads, upload_id) do
      nil ->
        {:error, %Firkin.Error{code: :no_such_upload}}

      upload ->
        combined =
          upload.parts
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join(fn {_, part} -> part.body end)

        etag = :crypto.hash(:md5, combined) |> Base.encode16(case: :lower)

        object = %{
          body: combined,
          content_type: "application/octet-stream",
          size: byte_size(combined),
          etag: etag,
          last_modified: DateTime.utc_now(),
          metadata: %{}
        }

        :ets.insert(@table, {:objects, Map.put(objects, {bucket, key}, object)})
        :ets.insert(@table, {:uploads, Map.delete(uploads, upload_id)})

        {:ok,
         %Firkin.CompleteResult{
           location: "/#{bucket}/#{key}",
           bucket: bucket,
           key: key,
           etag: etag
         }}
    end
  end

  @impl true
  def abort_multipart_upload(_ctx, _bucket, _key, upload_id) do
    [{:uploads, uploads}] = :ets.lookup(@table, :uploads)

    if Map.has_key?(uploads, upload_id) do
      :ets.insert(@table, {:uploads, Map.delete(uploads, upload_id)})
      :ok
    else
      {:error, %Firkin.Error{code: :no_such_upload}}
    end
  end

  @impl true
  def list_multipart_uploads(_ctx, bucket, _opts) do
    [{:uploads, uploads}] = :ets.lookup(@table, :uploads)

    upload_list =
      uploads
      |> Enum.filter(fn {_, u} -> u.bucket == bucket end)
      |> Enum.map(fn {id, u} ->
        %{key: u.key, upload_id: id, initiated: u.initiated}
      end)

    {:ok, %Firkin.MultipartList{bucket: bucket, uploads: upload_list}}
  end

  @impl true
  def list_parts(_ctx, _bucket, _key, upload_id, _opts) do
    [{:uploads, uploads}] = :ets.lookup(@table, :uploads)

    case Map.get(uploads, upload_id) do
      nil ->
        {:error, %Firkin.Error{code: :no_such_upload}}

      upload ->
        parts =
          upload.parts
          |> Enum.map(fn {num, part} ->
            %{
              part_number: num,
              etag: part.etag,
              size: part.size,
              last_modified: DateTime.utc_now()
            }
          end)
          |> Enum.sort_by(& &1.part_number)

        {:ok,
         %Firkin.PartList{
           bucket: upload.bucket,
           key: upload.key,
           upload_id: upload_id,
           parts: parts
         }}
    end
  end
end
