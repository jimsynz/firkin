defmodule Firkin.MultipartList do
  @moduledoc """
  Result of a ListMultipartUploads operation.
  """

  @type upload_entry :: %{
          key: String.t(),
          upload_id: String.t(),
          initiated: DateTime.t()
        }

  @type t :: %__MODULE__{
          bucket: String.t(),
          uploads: [upload_entry()],
          is_truncated: boolean(),
          max_uploads: pos_integer()
        }

  @enforce_keys [:bucket]
  defstruct [:bucket, uploads: [], is_truncated: false, max_uploads: 1000]
end
