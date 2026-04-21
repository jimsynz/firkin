defmodule Firkin.PartList do
  @moduledoc """
  Result of a ListParts operation.
  """

  @type part_entry :: %{
          part_number: pos_integer(),
          etag: String.t(),
          size: non_neg_integer(),
          last_modified: DateTime.t()
        }

  @type t :: %__MODULE__{
          bucket: String.t(),
          key: String.t(),
          upload_id: String.t(),
          parts: [part_entry()],
          is_truncated: boolean(),
          max_parts: pos_integer()
        }

  @enforce_keys [:bucket, :key, :upload_id]
  defstruct [:bucket, :key, :upload_id, parts: [], is_truncated: false, max_parts: 1000]
end
