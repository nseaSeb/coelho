defmodule Coelho.EditorParityTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Render, Schema}

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp text(text), do: %{"type" => "text", "text" => text}

  defp styled do
    Schema.extend(Schema.default(),
      nodes: [
        callout: [
          content: "inline*",
          group: "block",
          class: "callout",
          editor_attrs: %{"data-callout" => "true"},
          render: {"aside", []}
        ]
      ],
      marks: [
        highlight: [class: "hl hl-gradient", render: {"mark", [{"class", "base"}]}],
        effect: [class: "rainbow", render: {"span", []}]
      ]
    )
  end

  describe "class" do
    test "is applied by the server renderer" do
      {:ok, document} =
        Document.validate(doc([%{"type" => "callout", "content" => [text("x")]}]), styled())

      assert Render.to_html(document, styled()) == ~s(<aside class="callout">x</aside>)
    end

    test "is added after a class the render already sets, not instead of it" do
      {:ok, marked} =
        Document.validate(
          doc([
            %{
              "type" => "paragraph",
              "content" => [
                %{"type" => "text", "text" => "x", "marks" => [%{"type" => "highlight"}]}
              ]
            }
          ]),
          styled()
        )

      assert Render.to_html(marked, styled()) ==
               ~s(<p><mark class="base hl hl-gradient">x</mark></p>)
    end

    test "is exported to the browser, so the editor shows the same class" do
      exported = Schema.to_json(styled())

      assert {_name, spec} =
               Enum.find_value(exported["nodes"], fn [name, spec] ->
                 if name == "callout", do: {name, spec}
               end)

      assert spec["editorAttrs"] == %{"class" => "callout", "data-callout" => "true"}
    end

    test "a mark carries its class to the browser too" do
      exported = Schema.to_json(styled())

      marks = Map.new(exported["marks"], fn [name, spec] -> {name, spec} end)

      assert marks["highlight"]["editorAttrs"] == %{"class" => "hl hl-gradient"}
      assert marks["effect"]["editorAttrs"] == %{"class" => "rainbow"}
    end

    test "a spec that declares neither exports no editorAttrs key" do
      nodes = Map.new(Schema.to_json(Schema.default())["nodes"], fn [n, s] -> {n, s} end)

      refute Map.has_key?(nodes["paragraph"], "editorAttrs")
    end

    test "is refused when it is not a string" do
      assert_raise ArgumentError, ~r/must be a string/, fn ->
        Schema.extend(Schema.default(), marks: [bad: [class: :nope, render: {"b", []}]])
      end
    end

    test "editor_attrs must map names to strings" do
      assert_raise ArgumentError, ~r/must map names to strings/, fn ->
        Schema.extend(Schema.default(), marks: [bad: [editor_attrs: %{"a" => 1}]])
      end
    end
  end

  describe "align" do
    defp aligned(type, align, content \\ [%{"type" => "text", "text" => "x"}]) do
      doc([%{"type" => type, "attrs" => %{"align" => align}, "content" => content}])
    end

    test "renders as a text-align style on a paragraph, a heading and a list item" do
      {:ok, document} = Document.validate(aligned("paragraph", "center"), Schema.default())
      assert Coelho.to_html(document) == ~s(<p style="text-align:center">x</p>)

      {:ok, document} = Document.validate(aligned("heading", "right"), Schema.default())
      assert Coelho.to_html(document) == ~s(<h1 style="text-align:right">x</h1>)

      list =
        doc([
          %{
            "type" => "bullet_list",
            "content" => [
              %{
                "type" => "list_item",
                "attrs" => %{"align" => "justify"},
                "content" => [%{"type" => "paragraph", "content" => [text("x")]}]
              }
            ]
          }
        ])

      {:ok, document} = Document.validate(list, Schema.default())
      assert Coelho.to_html(document) =~ ~s(<li style="text-align:justify">)
    end

    test "is absent from the document, and from the markup, when unset" do
      {:ok, document} =
        Document.validate(
          doc([%{"type" => "paragraph", "content" => [text("x")]}]),
          Schema.default()
        )

      refute Map.has_key?(hd(document["content"]), "attrs")
      assert Coelho.to_html(document) == "<p>x</p>"
    end

    test "refuses a value outside the four it allows" do
      assert {:error, [error]} =
               Document.validate(aligned("paragraph", "middle"), Schema.default())

      assert error.message =~ "must be one of"
    end

    test "is read back from both the style and the attribute on import" do
      assert {:ok, from_style, _} = Coelho.from_html(~s(<p style="text-align:center">x</p>))
      assert Render.attr(hd(from_style["content"]), "align") == "center"

      assert {:ok, from_attr, _} = Coelho.from_html(~s(<h2 align="right">x</h2>))
      assert Render.attr(hd(from_attr["content"]), "align") == "right"
    end

    test "survives a round trip through the renderer and the importer" do
      html = ~s(<p style="text-align:center">x</p>)

      assert {:ok, document, _} = Coelho.from_html(html)
      assert Coelho.to_html(document) == html
    end

    test "a value the renderer cannot trust falls back to no style" do
      # A row written under a looser schema still renders through today's
      # renderer, so the closed list is checked again on the way out.
      assert Coelho.to_html(%{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "paragraph",
                   "attrs" => %{"align" => "expression(alert(1))"},
                   "content" => [text("x")]
                 }
               ]
             }) == "<p>x</p>"
    end
  end
end
