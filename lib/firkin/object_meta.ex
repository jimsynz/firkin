defmodule Firkin.ObjectMeta do
  @moduledoc """
  Object metadata returned by HeadObject and used in ListObjectsV2 entries.
  """

  @type t :: %__MODULE__{
          key: String.t(),
          etag: String.t(),
          size: non_neg_integer(),
          last_modified: DateTime.t(),
          content_type: String.t(),
          metadata: %{String.t() => String.t()},
          storage_class: String.t()
        }

  @enforce_keys [:key, :etag, :size, :last_modified]
  defstruct [
    :key,
    :etag,
    :size,
    :last_modified,
    content_type: "application/octet-stream",
    metadata: %{},
    storage_class: "STANDARD"
  ]
end
