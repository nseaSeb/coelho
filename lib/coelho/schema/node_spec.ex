defmodule Coelho.Schema.NodeSpec do
  @moduledoc """
  Specification of a single node type.

  Fields:

    * `:name` — the node name, an atom
    * `:content` — parsed content expression, `nil` for a leaf node
    * `:content_source` — the original expression, kept for JSON export
    * `:group` — group names this node belongs to
    * `:marks` — `:all`, or the list of mark names allowed on its children
    * `:attrs` — map of attribute name to `Coelho.Schema.Attr`
    * `:inline` — whether the node is inline rather than block
    * `:text` — set only on the built-in `text` node
    * `:void` — rendered as a self-closing tag, without children
    * `:render` — how the node is turned into HTML, see `Coelho.Render`
    * `:to_text` — what the node contributes to the plain text extraction,
      when that is not simply its children
    * `:parse` — HTML this node is imported from, see `Coelho.HTML`

  """

  alias Coelho.Schema.Attr

  @type render ::
          nil
          | {String.t(), [{String.t(), String.t()}] | (map() -> [{String.t(), String.t()}])}
          | (map(), iodata() -> iodata())

  @type t :: %__MODULE__{
          name: atom(),
          content: Coelho.Schema.ContentExpression.ast() | nil,
          content_source: String.t() | nil,
          group: [atom()],
          marks: :all | [atom()],
          attrs: %{optional(atom()) => Attr.t()},
          inline: boolean(),
          text: boolean(),
          void: boolean(),
          render: render(),
          to_text: String.t() | (map() -> iodata()) | nil,
          parse: [Coelho.HTML.rule()]
        }

  defstruct [
    :name,
    :content,
    :content_source,
    group: [],
    marks: :all,
    attrs: %{},
    inline: false,
    text: false,
    void: false,
    render: nil,
    to_text: nil,
    parse: []
  ]
end
