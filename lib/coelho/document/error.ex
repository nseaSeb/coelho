defmodule Coelho.Document.Error do
  @moduledoc """
  A single validation failure, located in the document tree.

  The `:path` is a list of segments from the root: string keys for map
  fields, integers for positions inside `content`.
  """

  @type segment :: String.t() | non_neg_integer()
  @type t :: %__MODULE__{path: [segment()], message: String.t()}

  defstruct path: [], message: ""

  @doc """
  Renders an error as `content[0].attrs.href: message`.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{path: path, message: message}) do
    case format_path(path) do
      "" -> message
      path -> "#{path}: #{message}"
    end
  end

  @doc """
  Renders a path as `content[0].attrs.href`, or `""` for the document itself.
  """
  @spec format_path([segment()]) :: String.t()
  def format_path(path) do
    path
    |> Enum.reduce("", fn
      segment, "" when is_binary(segment) -> segment
      segment, acc when is_binary(segment) -> acc <> "." <> segment
      segment, acc when is_integer(segment) -> acc <> "[" <> Integer.to_string(segment) <> "]"
    end)
  end
end
