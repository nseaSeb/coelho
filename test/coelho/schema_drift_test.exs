defmodule Coelho.SchemaDriftTest do
  use ExUnit.Case, async: true

  alias Coelho.Schema

  # The schema is declared once in Elixir and exported to the browser, with
  # one exception: `toDOM` and `parseDOM` are functions, so they live in
  # assets/js/coelho.js. That file is therefore the only place the two halves
  # can drift apart — a node added to the default schema and forgotten there
  # would build a ProseMirror schema that throws at editor mount, in the
  # browser, at runtime. This test is the guard.

  @source Path.expand("../../assets/js/coelho.js", __DIR__)
  @external_resource @source

  # `text` needs no DOM mapping: ProseMirror builds text nodes itself. `doc`
  # is the top node and is never rendered as an element.
  @without_dom ~w(doc text)a

  defp keys_of(object) do
    source = File.read!(@source)

    [_, body] =
      Regex.run(~r/export const #{object} = \{(.*?)\n\};/s, source) ||
        flunk("#{object} not found in #{@source}")

    ~r/^  ([a-z_]+): \{/m |> Regex.scan(body) |> Enum.map(fn [_, name] -> name end)
  end

  test "every default schema node has a DOM mapping in the hook" do
    declared =
      Schema.default().node_order
      |> Enum.reject(&(&1 in @without_dom))
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    assert Enum.sort(keys_of("defaultNodeDOM")) == declared
  end

  test "every default schema mark has a DOM mapping in the hook" do
    declared = Schema.default().mark_order |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    assert Enum.sort(keys_of("defaultMarkDOM")) == declared
  end

  test "the hook builds its schema from the exported ordering, not from an object" do
    source = File.read!(@source)

    # Node order decides ProseMirror's default types, and an object literal
    # would lose it.
    assert source =~ "addToEnd"
    assert source =~ "exported.nodes"
  end
end
