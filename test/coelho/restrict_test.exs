defmodule Coelho.RestrictTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Schema}

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp portal do
    Schema.restrict(Schema.default(), nodes: [:paragraph], marks: [:bold, :link])
  end

  describe "restrict/2" do
    test "keeps what was named" do
      assert {:ok, _} =
               Document.validate(
                 doc([paragraph([text("x", [%{"type" => "bold"}])])]),
                 portal()
               )
    end

    test "drops a node that was not" do
      document = doc([%{"type" => "heading", "content" => [text("T")]}])

      assert {:error, [error]} = Document.validate(document, portal())
      assert error.message =~ ~s(unknown node type "heading")
    end

    test "drops a mark that was not" do
      document = doc([paragraph([text("x", [%{"type" => "italic"}])])])

      assert {:error, [error]} = Document.validate(document, portal())
      assert error.message =~ "italic"
    end

    test "keeps the top node and the text node without being asked" do
      restricted = Schema.restrict(Schema.default(), nodes: [:paragraph])

      assert Map.has_key?(restricted.nodes, :doc)
      assert Map.has_key?(restricted.nodes, :text)
    end

    test "narrows the exported schema too, so the editor cannot produce more" do
      exported = Schema.to_json(portal())

      assert Enum.map(exported["nodes"], &hd/1) == ["doc", "paragraph", "text"]
      assert Enum.map(exported["marks"], &hd/1) == ["bold", "link"]
    end

    test "takes a removed mark out of the lists that named it" do
      # `code_block` names no mark at all, but a node that did would otherwise
      # refer to something the narrowing removed, and the schema would not
      # build.
      schema =
        Schema.new(
          top_node: :doc,
          nodes: [
            doc: [content: "paragraph+"],
            paragraph: [content: "inline*", marks: [:bold, :italic], render: {"p", []}]
          ],
          marks: [bold: [render: {"strong", []}], italic: [render: {"em", []}]]
        )

      restricted = Schema.restrict(schema, marks: [:bold])

      assert restricted.nodes[:paragraph].marks == [:bold]
    end

    test "leaving a key out narrows nothing" do
      restricted = Schema.restrict(Schema.default(), marks: [:bold])

      assert Map.keys(restricted.nodes) == Map.keys(Schema.default().nodes)
    end

    test "refuses a name the parent does not have" do
      assert_raise ArgumentError, ~r/no such node/, fn ->
        Schema.restrict(Schema.default(), nodes: [:callout])
      end

      assert_raise ArgumentError, ~r/no such mark/, fn ->
        Schema.restrict(Schema.default(), marks: [:highlight])
      end
    end

    test "refuses a keep list that is not a list" do
      assert_raise ArgumentError, ~r/expects a list of nodes/, fn ->
        Schema.restrict(Schema.default(), nodes: :paragraph)
      end
    end

    test "refuses a narrowing that leaves a survivor pointing at nothing" do
      error =
        assert_raise ArgumentError, fn ->
          Schema.restrict(Schema.default(), nodes: [:paragraph, :bullet_list])
        end

      assert error.message =~ "list_item"
      assert error.message =~ "restrict/2"
    end
  end

  describe "the guarantee" do
    test "a restricted schema never accepts what its parent rejects" do
      parent = Schema.default()
      child = portal()

      hostile = [
        doc([%{"type" => "script"}]),
        doc([paragraph([text("x", [%{"type" => "blink"}])])]),
        doc([paragraph([%{"type" => "image", "attrs" => %{"src" => "javascript:x"}}])])
      ]

      for document <- hostile do
        assert {:error, _} = Document.validate(document, parent)
        assert {:error, _} = Document.validate(document, child)
      end
    end

    test "limits only tighten" do
      parent = Schema.extend(Schema.default(), limits: [max_nodes: 100])

      assert Schema.restrict(parent, limits: [max_nodes: 10]).limits.max_nodes == 10
      assert Schema.restrict(parent, limits: [max_nodes: 1000]).limits.max_nodes == 100
    end
  end
end
