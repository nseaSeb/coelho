defmodule Coelho.Schema.MarkSpec do
  @moduledoc """
  Specification of a single mark type, such as `bold` or `link`.

  Fields:

    * `:name` — the mark name, an atom
    * `:attrs` — map of attribute name to `Coelho.Schema.Attr`
    * `:class` — a CSS class merged into the rendered element *and* exported
      to the browser, so the editor shows the class the public page will use
    * `:editor_attrs` — extra DOM attributes for the editor only, exported
      with the schema and never emitted server side
    * `:render` — how the mark is turned into HTML, see `Coelho.Render`
    * `:parse` — HTML this mark is imported from, see `Coelho.HTML`
    * `:attr_keys` — the attribute names as the strings a document is written
      in, derived from `:attrs` when the schema is built

  """

  alias Coelho.Schema.Attr

  @type t :: %__MODULE__{
          name: atom(),
          attrs: %{optional(atom()) => Attr.t()},
          class: String.t() | nil,
          editor_attrs: %{optional(String.t()) => String.t()},
          render: Coelho.Schema.NodeSpec.render(),
          parse: [Coelho.HTML.rule()],
          attr_keys: MapSet.t(String.t()) | nil
        }

  defstruct [
    :name,
    :class,
    attrs: %{},
    editor_attrs: %{},
    render: nil,
    parse: [],
    attr_keys: nil
  ]
end
