defmodule Firkin.Test.NonStreamingBackend do
  @moduledoc """
  Stand-in backend that implements only the buffered `put_object/5` and
  `upload_part/6` callbacks (no streaming variants). Used to exercise the
  Plug's buffered path and the `:max_buffered_put_bytes` cap.
  """
  @behaviour Firkin.Backend

  @table __MODULE__

  @spec start :: :ok
  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:credentials, %{}})
    :ets.insert(@table, {:buckets, %{}})
    :ets.insert(@table, {:objects, %{}})
    :ets.insert(@table, {:uploads, %{}})
    :ok
  end

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
  def list_buckets(_ctx), do: {:ok, []}

  @impl true
  def create_bucket(_ctx, bucket) do
    [{:buckets, buckets}] = :ets.lookup(@table, :buckets)
    :ets.insert(@table, {:buckets, Map.put(buckets, bucket, true)})
    :ok
  end

  @impl true
  def delete_bucket(_ctx, _bucket), do: :ok

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
  def get_bucket_location(_ctx, _bucket), do: {:ok, "us-east-1"}

  @impl true
  def get_object(_ctx, _bucket, _key, _opts),
    do: {:error, %Firkin.Error{code: :no_such_key}}

  @impl true
  def put_object(_ctx, _bucket, _key, body, _opts) do
    etag =
      body
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    {:ok, etag}
  end

  @impl true
  def delete_object(_ctx, _bucket, _key), do: :ok

  @impl true
  def delete_objects(_ctx, _bucket, _keys),
    do: {:ok, %Firkin.DeleteResult{deleted: [], errors: []}}

  @impl true
  def head_object(_ctx, _bucket, _key),
    do: {:error, %Firkin.Error{code: :no_such_key}}

  @impl true
  def list_objects_v2(_ctx, bucket, _opts),
    do:
      {:ok,
       %Firkin.ListResult{
         name: bucket,
         prefix: nil,
         delimiter: nil,
         contents: [],
         common_prefixes: [],
         key_count: 0,
         max_keys: 1000,
         is_truncated: false
       }}

  @impl true
  def copy_object(_ctx, _bucket, _key, _src_bucket, _src_key),
    do: {:error, %Firkin.Error{code: :no_such_key}}

  @impl true
  def create_multipart_upload(_ctx, _bucket, _key, _opts) do
    upload_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    [{:uploads, uploads}] = :ets.lookup(@table, :uploads)
    :ets.insert(@table, {:uploads, Map.put(uploads, upload_id, true)})
    {:ok, upload_id}
  end

  @impl true
  def upload_part(_ctx, _bucket, _key, _upload_id, _part_number, body) do
    etag =
      body
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    {:ok, etag}
  end

  @impl true
  def complete_multipart_upload(_ctx, bucket, key, _upload_id, _parts) do
    {:ok,
     %Firkin.CompleteResult{
       location: "/#{bucket}/#{key}",
       bucket: bucket,
       key: key,
       etag: "deadbeef"
     }}
  end

  @impl true
  def abort_multipart_upload(_ctx, _bucket, _key, _upload_id), do: :ok

  @impl true
  def list_multipart_uploads(_ctx, bucket, _opts),
    do: {:ok, %Firkin.MultipartList{bucket: bucket, uploads: []}}

  @impl true
  def list_parts(_ctx, bucket, key, upload_id, _opts),
    do:
      {:ok,
       %Firkin.PartList{
         bucket: bucket,
         key: key,
         upload_id: upload_id,
         parts: []
       }}
end
