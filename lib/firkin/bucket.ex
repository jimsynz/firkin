defmodule Firkin.Bucket do
  @moduledoc """
  Represents an S3 bucket in listing responses.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          creation_date: DateTime.t()
        }

  @enforce_keys [:name, :creation_date]
  defstruct [:name, :creation_date]
end
