defmodule Firkin.GetOpts do
  @moduledoc """
  Options for GetObject, including range and conditional request headers.
  """

  @type t :: %__MODULE__{
          range: {non_neg_integer(), non_neg_integer()} | nil,
          if_match: String.t() | nil,
          if_none_match: String.t() | nil,
          if_modified_since: DateTime.t() | nil,
          if_unmodified_since: DateTime.t() | nil
        }

  defstruct [:range, :if_match, :if_none_match, :if_modified_since, :if_unmodified_since]
end
