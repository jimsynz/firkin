defmodule Firkin.GetOpts do
  @moduledoc """
  Options for GetObject, including range and conditional request headers.
  """

  @typedoc """
  A single byte range as described by RFC 7233 §2.1.

    * `{first, last}` — the bytes from `first` to `last`, inclusive.
    * `{first, nil}` — from `first` to the end of the object.
    * `{nil, suffix}` — the final `suffix` bytes of the object.

  The open bounds cannot be resolved when the request is parsed because
  the object's size is not known until the backend looks it up, so
  backends must call `resolve_range/2` before applying the range.
  """
  @type range :: {non_neg_integer(), non_neg_integer() | nil} | {nil, non_neg_integer()}

  @type t :: %__MODULE__{
          range: range() | nil,
          if_match: String.t() | nil,
          if_none_match: String.t() | nil,
          if_modified_since: DateTime.t() | nil,
          if_unmodified_since: DateTime.t() | nil
        }

  defstruct [:range, :if_match, :if_none_match, :if_modified_since, :if_unmodified_since]

  @doc """
  Resolves a byte range against the size of the object it applies to.

  Returns `{:ok, {first, last}}` with both bounds present and clamped to
  the object, `:none` when the request had no range, or `:unsatisfiable`
  when the range names no bytes of the object — in which case the backend
  should return `{:error, %Firkin.Error{code: :invalid_range}}` and the
  Plug will respond with `416 Requested Range Not Satisfiable`.

  ## Examples

      iex> Firkin.GetOpts.resolve_range({2, 5}, 11)
      {:ok, {2, 5}}

      iex> Firkin.GetOpts.resolve_range({2, 99}, 11)
      {:ok, {2, 10}}

      iex> Firkin.GetOpts.resolve_range({6, nil}, 11)
      {:ok, {6, 10}}

      iex> Firkin.GetOpts.resolve_range({nil, 5}, 11)
      {:ok, {6, 10}}

      iex> Firkin.GetOpts.resolve_range({nil, 99}, 11)
      {:ok, {0, 10}}

      iex> Firkin.GetOpts.resolve_range({11, nil}, 11)
      :unsatisfiable

      iex> Firkin.GetOpts.resolve_range({nil, 0}, 11)
      :unsatisfiable

      iex> Firkin.GetOpts.resolve_range(nil, 11)
      :none
  """
  @spec resolve_range(range() | nil, non_neg_integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | :none | :unsatisfiable
  def resolve_range(nil, _total_size), do: :none

  def resolve_range(_range, 0), do: :unsatisfiable

  def resolve_range({nil, 0}, _total_size), do: :unsatisfiable

  def resolve_range({nil, suffix_length}, total_size),
    do: {:ok, {max(0, total_size - suffix_length), total_size - 1}}

  def resolve_range({first, _last}, total_size) when first >= total_size, do: :unsatisfiable

  def resolve_range({first, nil}, total_size), do: {:ok, {first, total_size - 1}}

  def resolve_range({first, last}, total_size), do: {:ok, {first, min(last, total_size - 1)}}
end
