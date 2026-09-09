defmodule Coelho.TablesTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Render, Schema}

  defp schema, do: Schema.Default.build(tables: true)

  defp cell(tag, text, attrs \\ %{}) do
    %{
      "type" => tag,
      "attrs" => attrs,
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}]
    }
  end

  defp row(cells), do: %{"type" => "table_row", "content" => cells}
  defp table(rows), do: %{"type" => "table", "content" => rows}
  defp doc(content), do: %{"type" => "doc", "content" => content}

  defp two_by_two do
    doc([
      table([
        row([cell("table_header", "a"), cell("table_header", "b")]),
        row([cell("table_cell", "1"), cell("table_cell", "2")])
      ])
    ])
  end

  describe "the option" do
    test "is off unless it is asked for" do
      refute Map.has_key?(Schema.Default.build().nodes, :table)
      assert Map.has_key?(schema().nodes, :table)
    end

    test "changes the fingerprint, so an editor notices" do
      refute Schema.Default.build().fingerprint == schema().fingerprint
    end

    test "leaves the first suitable block alone" do
      # `block+` is satisfied by the first block the schema declares, which
      # is how a bare `Hello` becomes a paragraph. Declaring tables must not
      # make it a table.
      {:ok, imported, _warnings} = Coelho.HTML.from_html("Hello", schema(), warnings: true)

      assert %{"content" => [%{"type" => "paragraph"}]} = imported
    end

    test "a document holding a table is refused by the schema without them" do
      assert {:error, _} = Document.validate(two_by_two(), Schema.Default.build())
    end
  end

  describe "a table" do
    test "validates, renders and reduces to its text" do
      {:ok, document} = Document.validate(two_by_two(), schema())

      assert Render.to_html(document, schema()) ==
               "<table><tr><th><p>a</p></th><th><p>b</p></th></tr>" <>
                 "<tr><td><p>1</p></td><td><p>2</p></td></tr></table>"

      assert Document.to_text(document, schema()) == "a\nb\n1\n2"
    end

    test "needs a row, and a row needs a cell" do
      assert {:error, _} = Document.validate(doc([table([])]), schema())
      assert {:error, _} = Document.validate(doc([table([row([])])]), schema())
    end

    test "holds blocks in a cell, not only text" do
      quoted = %{
        "type" => "blockquote",
        "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "q"}]}]
      }

      document = doc([table([row([%{"type" => "table_cell", "content" => [quoted]}])])])

      assert {:ok, _} = Document.validate(document, schema())
    end
  end

  describe "a span" do
    defp spanned(value) do
      doc([table([row([cell("table_cell", "x", %{"colspan" => value})])])])
    end

    test "is written only when it is more than one cell" do
      {:ok, one} = Document.validate(spanned(1), schema())
      {:ok, two} = Document.validate(spanned(2), schema())

      refute Render.to_html(one, schema()) =~ "colspan"
      assert Render.to_html(two, schema()) =~ ~s(colspan="2")
    end

    test "is a count of cells, and a bounded one" do
      for refused <- [0, -1, 1_000_000, "2", 1.5, nil] do
        assert {:error, [error | _]} = Document.validate(spanned(refused), schema())
        assert error.message =~ "whole number of cells"
      end
    end

    test "is clamped at render, for a row written under a looser schema" do
      # The same pair the heading level has: refused on the way in, and left
      # out on the way to the page, because what is stored was written under
      # whatever was in force then.
      assert Render.to_html(spanned(1_000_000), schema()) ==
               "<table><tr><td><p>x</p></td></tr></table>"
    end
  end

  describe "importing HTML" do
    @html ~s(<table><tr><th colspan="2">a</th></tr><tr><td rowspan="3">1</td></tr></table>)

    test "keeps the table, where the schema without them warns and drops it" do
      assert {:ok, document, []} = Coelho.HTML.from_html(@html, schema(), warnings: true)

      assert Render.to_html(document, schema()) ==
               ~s(<table><tr><th colspan="2"><p>a</p></th></tr>) <>
                 ~s(<tr><td rowspan="3"><p>1</p></td></tr></table>)

      assert {:ok, _dropped, warnings} =
               Coelho.HTML.from_html(@html, Schema.Default.build(), warnings: true)

      assert %{kind: :unknown_element, tag: "table"} = hd(warnings)
    end

    test "says nothing about the wrappers a browser writes and a schema has no use for" do
      # Every table a browser serialises carries a `tbody`, and a word
      # processor adds `colgroup` besides. Those hold nothing of their own —
      # the rows lift straight through — so reporting them would say a table
      # had lost something on every real table there is.
      html = """
      <table><colgroup><col></colgroup>
        <thead><tr><th>h</th></tr></thead>
        <tbody><tr><td>a</td></tr></tbody>
      </table>
      """

      assert {:ok, document, []} = Coelho.HTML.from_html(html, schema(), warnings: true)

      assert Render.to_html(document, schema()) ==
               "<table><tr><th><p>h</p></th></tr><tr><td><p>a</p></td></tr></table>"

      # A caption is not one of them: what it holds is text, and the text is
      # lost.
      assert {:ok, _document, [%{tag: "caption"}]} =
               Coelho.HTML.from_html(
                 "<table><caption>c</caption><tr><td>a</td></tr></table>",
                 schema(),
                 warnings: true
               )
    end

    test "reads a span the browser wrote, and ignores one it could not have" do
      for {written, expected} <- [{~s( colspan="3"), ~s(colspan="3")}, {~s( colspan="x"), nil}] do
        html = "<table><tr><td#{written}>a</td></tr></table>"
        {:ok, document, _warnings} = Coelho.HTML.from_html(html, schema(), warnings: true)
        rendered = Render.to_html(document, schema())

        if expected, do: assert(rendered =~ expected), else: refute(rendered =~ "colspan")
      end
    end
  end
end
