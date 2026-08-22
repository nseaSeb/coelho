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
    * `:class` — a CSS class merged into the rendered element *and* exported
      to the browser, so the editor shows the class the public page will use
    * `:editor_attrs` — extra DOM attributes for the editor only, exported
      with the schema and never emitted server side
    * `:render` — how the node is turned into HTML, see `Coelho.Render`
    * `:render_inline` — how it is turned into HTML where only inline
      elements are legal. A block is unwrapped to its children by default,
      which is right for a paragraph and useless for a node whose block-ness
      lives inside a render function — see `Coelho.Render.to_inline_html/3`
    * `:to_text` — what the node contributes to the plain text extraction,
      when that is not simply its children
    * `:editor_text` — the attribute whose value the editor draws as the
      node's visible text. A void node has no content, so a chip standing for
      a variable, a mention or a date would otherwise draw empty; naming an
      attribute here is what puts words in it, on the browser's side only —
      the server's `:render` decides what the page carries
    * `:parse` — HTML this node is imported from, see `Coelho.HTML`
    * `:attr_keys` — the attribute names as the strings a document is written
      in, derived from `:attrs` when the schema is built. Validation asks
      this of every node instance, and building it there would be a set per
      node of every document.

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
          class: String.t() | nil,
          editor_attrs: %{optional(String.t()) => String.t()},
          render: render(),
          render_inline: render(),
          to_text: String.t() | (map() -> iodata()) | nil,
          editor_text: atom() | nil,
          parse: [Coelho.HTML.rule()],
          attr_keys: MapSet.t(String.t()) | nil
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
    class: nil,
    editor_attrs: %{},
    render: nil,
    render_inline: nil,
    to_text: nil,
    editor_text: nil,
    parse: [],
    attr_keys: nil
  ]
end
