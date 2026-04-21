defmodule Firkin.DeleteResult do
  @moduledoc """
  Result of a DeleteObjects (batch delete) operation.
  """

  @type deleted_entry :: %{key: String.t()}

  @type error_entry :: %{
          key: String.t(),
          code: String.t(),
          message: String.t()
        }

  @type t :: %__MODULE__{
          deleted: [deleted_entry()],
          errors: [error_entry()]
        }

  defstruct deleted: [], errors: []
end
