defmodule Firkin.ListOpts do
  @moduledoc """
  Options for ListObjectsV2.
  """

  @type t :: %__MODULE__{
          prefix: String.t() | nil,
          delimiter: String.t() | nil,
          max_keys: pos_integer(),
          continuation_token: String.t() | nil,
          start_after: String.t() | nil,
          fetch_owner: boolean()
        }

  defstruct [
    :prefix,
    :delimiter,
    :continuation_token,
    :start_after,
    max_keys: 1000,
    fetch_owner: false
  ]
end
