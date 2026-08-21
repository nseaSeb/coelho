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
  Takes an error apart, for an application that has to word it itself.

  `format/1` says `content[0].attrs.href: scheme "javascript" is not
  allowed`, which is right for a log and wrong for the person who pasted the
  link. Wording it for them needs their language and their vocabulary — a
  market gardener reads "the link in the first paragraph", not a path — and
  neither of those is Coelho's to choose. This gives the pieces:

      %{
        position: [1],
        scope: :attribute,
        attribute: "href",
        mark: 1,
        location: "content[0].marks[0].attrs.href",
        message: ~s(scheme "javascript" is not allowed)
      }

  `:position` counts from 1, down the content tree, so `[2, 1]` is the first
  child of the second block. `:scope` is `:document`, `:node`, `:mark` or
  `:attribute`. `:mark` is which mark on the node, from 1, when the failure
  is on one; `:attribute` is the attribute's name.

  What is deliberately absent is the *type* — which node, which mark. An
  error path carries positions, not names, and inventing them here would
  mean re-walking the document this error came from without being handed it.
  An application that needs the type has the document.

      case Coelho.Document.Error.describe(error) do
        %{scope: :attribute, attribute: "href", position: [n]} ->
          gettext("The link in paragraph %{n} is not allowed.", n: n)

        %{position: [n | _]} ->
          gettext("Paragraph %{n} could not be saved.", n: n)
      end

  """
  @type description :: %{
          position: [pos_integer()],
          scope: :document | :node | :mark | :attribute,
          attribute: String.t() | nil,
          mark: pos_integer() | nil,
          location: String.t(),
          message: String.t()
        }

  @spec describe(t()) :: description()
  def describe(%__MODULE__{path: path, message: message}) do
    {positions, tail} = split(path, [])
    {scope, attribute, mark} = scope(tail, positions)

    %{
      position: positions,
      scope: scope,
      attribute: attribute,
      mark: mark,
      location: format_path(path),
      message: message
    }
  end

  defp split(["content", index | rest], positions) when is_integer(index),
    do: split(rest, [index + 1 | positions])

  defp split(tail, positions), do: {Enum.reverse(positions), tail}

  # A failing attribute *on a mark* is described as an attribute, not as a
  # mark: what went wrong is the value someone typed, and that is what a
  # message has to name.
  defp scope(["marks", index, "attrs", key | _rest], _positions) when is_integer(index),
    do: {:attribute, key, index + 1}

  defp scope(["marks", index | _rest], _positions) when is_integer(index),
    do: {:mark, nil, index + 1}

  defp scope(["marks" | _rest], _positions), do: {:mark, nil, nil}
  defp scope(["attrs", key | _rest], _positions), do: {:attribute, key, nil}
  defp scope(["attrs"], _positions), do: {:attribute, nil, nil}
  defp scope(_tail, []), do: {:document, nil, nil}
  defp scope(_tail, _positions), do: {:node, nil, nil}

  @doc """
  An English sentence, for when there is no translator in the building.

  A default and not an answer: it reads `block 2, "href": scheme
  "javascript" is not allowed`, which is a great deal better than a dotted
  path and still not what you would write for your own readers. Use
  `describe/1` for that.
  """
  @spec humanize(t()) :: String.t()
  def humanize(%__MODULE__{} = error) do
    description = describe(error)

    case where(description) do
      "" -> description.message
      where -> where <> ": " <> description.message
    end
  end

  defp where(%{scope: :document}), do: "the document"

  defp where(%{position: positions} = description) do
    [blocks(positions), part(description)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp blocks([]), do: ""

  defp blocks([first | rest]) do
    ["block #{first}" | Enum.map(rest, &"item #{&1}")] |> Enum.join(", ")
  end

  defp part(%{scope: :attribute, attribute: nil}), do: "its attributes"
  defp part(%{scope: :attribute, attribute: attribute}), do: ~s("#{attribute}")
  defp part(%{scope: :mark}), do: "formatting"
  defp part(_description), do: ""

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
