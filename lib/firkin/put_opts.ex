defmodule Firkin.PutOpts do
  @moduledoc """
  Options for PutObject.
  """

  @type t :: %__MODULE__{
          content_type: String.t(),
          metadata: %{String.t() => String.t()}
        }

  defstruct content_type: "application/octet-stream", metadata: %{}
end
