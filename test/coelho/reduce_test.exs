defmodule Coelho.ReduceTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Render, Schema}

  defp schema, do: Schema.default()

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp validate!(document) do
    {:ok, document} = Document.validate(document, schema())
    document
  end

  # What a non-HTML target looks like: a tree of plain maps, handed to an
  # encoder that does its own quoting, so nothing typed is ever concatenated
  # into something a downstream language would read as code.
  defp callbacks do
    %{
      text: fn text, marks -> %{"text" => text, "marks" => Enum.map(marks, & &1["type"])} end,
      node: fn node, children -> %{"block" => node["type"], "children" => children} end
    }
  end

  describe "reduce/4" do
    test "returns a term, not iodata" do
      document = validate!(doc([paragraph([text("hello")])]))

      assert Render.reduce(document, schema(), callbacks()) == %{
               "block" => "doc",
               "children" => [
                 %{
                   "block" => "paragraph",
                   "children" => [%{"text" => "hello", "marks" => []}]
                 }
               ]
             }
    end

    test "hands the text callback the resolved marks, in the schema's order" do
      document =
        validate!(
          doc([
            paragraph([
              text("x", [%{"type" => "link", "attrs" => %{"href" => "/a"}}, %{"type" => "bold"}])
            ])
          ])
        )

      assert %{"children" => [%{"children" => [%{"marks" => marks}]}]} =
               Render.reduce(document, schema(), callbacks())

      assert marks == ["bold", "link"]
    end

    test "a mark keeps its attributes" do
      document =
        validate!(
          doc([paragraph([text("x", [%{"type" => "link", "attrs" => %{"href" => "/a"}}])])])
        )

      assert [%{"attrs" => %{"href" => "/a"}}] =
               Render.reduce(document, schema(), %{
                 text: fn _text, marks -> marks end,
                 node: fn _node, children -> List.flatten(children) end
               })
    end

    test "text goes through the node callback when no text callback is given" do
      document = validate!(doc([paragraph([text("hello")])]))

      assert Render.reduce(document, schema(), %{
               node: fn node, children -> [node["type"] | children] end
             }) == ["doc", ["paragraph", ["text"]]]
    end

    test "a callback of arity three receives the context" do
      document = validate!(doc([paragraph([text("x")])]))

      assert Render.reduce(
               document,
               schema(),
               %{
                 text: fn text, _marks, context -> context.prefix <> text end,
                 node: fn _node, children -> children end
               },
               context: %{prefix: ">"}
             ) == [[">x"]]
    end

    test "folds a void node, which has no children" do
      document =
        validate!(doc([paragraph([%{"type" => "image", "attrs" => %{"src" => "/a.png"}}])]))

      assert Render.reduce(document, schema(), %{
               node: fn node, children -> {node["type"], children} end
             }) == {"doc", [{"paragraph", [{"image", []}]}]}
    end

    test "raises on a node the schema does not know, rather than skipping it" do
      assert_raise ArgumentError, ~r/unknown node type "script"/, fn ->
        Render.reduce(doc([%{"type" => "script"}]), schema(), callbacks())
      end
    end

    test "raises on a mark the schema does not know" do
      document = doc([paragraph([text("x", [%{"type" => "blink"}])])])

      assert_raise ArgumentError, ~r/unknown mark type "blink"/, fn ->
        Render.reduce(document, schema(), callbacks())
      end
    end

    test "the facade defaults to the shipped schema" do
      document = validate!(doc([paragraph([text("x")])]))

      assert Coelho.reduce(document, callbacks()) ==
               Render.reduce(document, schema(), callbacks())
    end
  end

  describe "attr/3" do
    test "reads an attribute that is present" do
      assert Render.attr(%{"attrs" => %{"level" => 3}}, "level", 1) == 3
    end

    test "falls back for one left at its schema default, which is not stored" do
      document = validate!(doc([%{"type" => "heading", "content" => [text("T")]}]))
      heading = hd(document["content"])

      refute Map.has_key?(heading, "attrs")
      assert Render.attr(heading, "level", 1) == 1
    end

    test "falls back when the node has no attributes at all" do
      assert Render.attr(%{"type" => "paragraph"}, "align", "left") == "left"
      assert Render.attr(%{"attrs" => "not a map"}, "align") == nil
    end
  end
end
