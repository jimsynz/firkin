defmodule Firkin.Object do
  @moduledoc """
  Represents an S3 object returned by GetObject.

  `content_length` is the size of `body` — the length of the range served,
  not of the whole object. `total_size` is the size of the whole object and
  is required whenever a range was applied, since the `Content-Range`
  response header names the object's full length.
  """

  @type t :: %__MODULE__{
          body: iodata() | Enumerable.t(),
          content_type: String.t(),
          content_length: non_neg_integer(),
          etag: String.t(),
          last_modified: DateTime.t(),
          metadata: %{String.t() => String.t()},
          total_size: non_neg_integer() | nil
        }

  @enforce_keys [:body, :content_length, :etag, :last_modified]
  defstruct [
    :body,
    :content_length,
    :etag,
    :last_modified,
    :total_size,
    content_type: "application/octet-stream",
    metadata: %{}
  ]
end
