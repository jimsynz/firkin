defmodule Firkin.Credential do
  @moduledoc """
  Represents an S3 credential pair with an opaque identity.

  The `identity` field is passed through to all backend callbacks as part of
  the auth context. The backend can put whatever it needs here — user ID,
  tenant, role, etc.
  """

  @type t :: %__MODULE__{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          identity: term()
        }

  @enforce_keys [:access_key_id, :secret_access_key]
  defstruct [:access_key_id, :secret_access_key, :identity]
end
