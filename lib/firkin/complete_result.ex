defmodule Firkin.CompleteResult do
  @moduledoc """
  Result of a CompleteMultipartUpload operation.
  """

  @type t :: %__MODULE__{
          location: String.t(),
          bucket: String.t(),
          key: String.t(),
          etag: String.t()
        }

  @enforce_keys [:location, :bucket, :key, :etag]
  defstruct [:location, :bucket, :key, :etag]
end
