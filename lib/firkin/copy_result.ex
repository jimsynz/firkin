defmodule Firkin.CopyResult do
  @moduledoc """
  Result of a CopyObject operation.
  """

  @type t :: %__MODULE__{
          etag: String.t(),
          last_modified: DateTime.t()
        }

  @enforce_keys [:etag, :last_modified]
  defstruct [:etag, :last_modified]
end
