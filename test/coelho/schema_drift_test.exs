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
    # Everything the library can declare, and not only what the default
    # schema ships: tables are an option, and the half of them that cannot
    # come from Elixir — the role `prosemirror-tables` reads — has to be
    # here for the day the option is taken.
    declared =
      Schema.Default.build(tables: true).node_order
      |> Enum.reject(&(&1 in @without_dom))
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    assert Enum.sort(keys_of("defaultNodeDOM")) == declared
  end

  test "every default schema mark is drawn by the hook or by its export" do
    # A mark whose `:render` is a declaration is exported as `renderDOM`, and
    # the hook builds its toDOM from that. One whose render is a function —
    # `link`, whose attributes are computed — is exported without it, and
    # needs a mapping here. A mapping here also *wins* over the export, so a
    # mark that does not need one must not have one: an application that
    # redeclares `highlight` would see its own render on the page and the
    # library's in the editor. `bold`, `italic`, `strike` and `code` keep
    # theirs for the style rules a paste from a word processor carries.
    exported = Map.new(Schema.to_json(Schema.default())["marks"], fn [n, spec] -> {n, spec} end)

    {drawn, undrawn} = Enum.split_with(exported, fn {_name, spec} -> spec["renderDOM"] end)

    assert Enum.sort(keys_of("defaultMarkDOM")) ==
             Enum.sort(~w(bold italic strike code) ++ Enum.map(undrawn, &elem(&1, 0)))

    for name <- ~w(underline highlight subscript superscript) do
      assert Map.has_key?(Map.new(drawn), name), "#{name} is not exported with its render"
    end
  end

  test "the node commands the server keeps are the ones the hook has a verb for" do
    # Each kind of node takes its own verb — toggle a block, wrap, list —
    # so `commandFor` names them one by one and `Coelho.LiveView` mirrors
    # that list to filter the toolbar. Two hand-kept lists in two
    # languages: a verb added to the hook and forgotten here would have its
    # button silently dropped by the server, with nothing to point at.
    source = File.read!(@source)

    [_, body] =
      Regex.run(~r/const commandFor = .*?\n  switch \(name\) \{(.*?)\n  \}/s, source) ||
        flunk("commandFor not found in #{@source}")

    labels = ~r/^    case "([a-z_]+)":/m |> Regex.scan(body) |> Enum.map(fn [_, n] -> n end)
    nodes = Schema.default().node_order |> Enum.map(&Atom.to_string/1)

    # `link` is a mark with a case of its own, `caption` an attribute, and
    # `undo`/`redo` belong to no vocabulary at all.
    assert Enum.sort(Enum.filter(labels, &(&1 in nodes))) ==
             Enum.sort(Coelho.LiveView.node_commands())
  end

  test "the table commands the server keeps are the ones the hook has a verb for" do
    # The same two hand-kept lists as above, for the family that acts on a
    # table rather than toggling a block. A verb added to one and not the
    # other is a button that does nothing, or one that is never drawn.
    source = File.read!(@source)

    [_, body] =
      Regex.run(~r/const commandFor = .*?\n  switch \(name\) \{(.*?)\n  \}/s, source) ||
        flunk("commandFor not found in #{@source}")

    cases = ~r/^    case "(table_[a-z_]+)":/m |> Regex.scan(body) |> Enum.map(fn [_, n] -> n end)

    assert Enum.sort(cases) == Enum.sort(Coelho.LiveView.table_commands())
  end

  test "the hook builds its schema from the exported ordering, not from an object" do
    source = File.read!(@source)

    # Node order decides ProseMirror's default types, and an object literal
    # would lose it.
    assert source =~ "addToEnd"
    assert source =~ "exported.nodes"
  end
end
