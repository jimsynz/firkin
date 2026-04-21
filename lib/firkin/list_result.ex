defmodule Firkin.ListResult do
  @moduledoc """
  Result of a ListObjectsV2 operation.
  """

  @type t :: %__MODULE__{
          contents: [Firkin.ObjectMeta.t()],
          common_prefixes: [String.t()],
          is_truncated: boolean(),
          continuation_token: String.t() | nil,
          next_continuation_token: String.t() | nil,
          key_count: non_neg_integer(),
          max_keys: non_neg_integer(),
          prefix: String.t() | nil,
          delimiter: String.t() | nil,
          name: String.t()
        }

  @enforce_keys [:name]
  defstruct [
    :continuation_token,
    :delimiter,
    :name,
    :next_continuation_token,
    :prefix,
    contents: [],
    common_prefixes: [],
    is_truncated: false,
    key_count: 0,
    max_keys: 1000
  ]
end
