defmodule Coelho.DocumentTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Schema}
  alias Coelho.Document.Error

  defp schema, do: Schema.default()

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp messages({:error, errors}), do: Enum.map(errors, &Error.format/1)

  describe "validate/2" do
    test "accepts a well formed document" do
      document = doc([paragraph([text("hello", [%{"type" => "bold"}])])])

      assert {:ok, ^document} = Document.validate(document, schema())
    end

    test "fills optional attributes with their schema default" do
      document = doc([%{"type" => "heading", "content" => [text("Title")]}])

      assert {:ok, normalised} = Document.validate(document, schema())
      assert [%{"attrs" => %{"level" => 1}}] = normalised["content"]
    end

    test "keeps an explicit attribute" do
      document =
        doc([%{"type" => "heading", "attrs" => %{"level" => 3}, "content" => [text("T")]}])

      assert {:ok, normalised} = Document.validate(document, schema())
      assert [%{"attrs" => %{"level" => 3}}] = normalised["content"]
    end

    test "rejects an unknown node type" do
      assert ["content[0]: unknown node type \"script\""] =
               doc([%{"type" => "script"}]) |> Document.validate(schema()) |> messages()
    end

    test "rejects an unknown attribute" do
      document = doc([%{"type" => "paragraph", "attrs" => %{"onclick" => "x"}, "content" => []}])

      assert ["content[0].attrs: unknown attribute \"onclick\""] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects an unknown key on a node" do
      document = doc([Map.put(paragraph([]), "style", "color:red")])

      assert ["content[0]: unknown key \"style\""] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects an out of range attribute value" do
      document = doc([%{"type" => "heading", "attrs" => %{"level" => 9}, "content" => []}])

      assert ["content[0].attrs.level: must be one of [1, 2, 3, 4, 5, 6]"] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects a missing required attribute" do
      document = doc([paragraph([%{"type" => "image", "attrs" => %{}}])])

      assert ["content[0].content[0].attrs.src: is required"] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects a javascript: URL on a link" do
      mark = %{"type" => "link", "attrs" => %{"href" => "javascript:alert(1)"}}
      document = doc([paragraph([text("click", [mark])])])

      assert ["content[0].content[0].marks[0].attrs.href: scheme \"javascript\" is not allowed"] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects a URL smuggling control characters past the scheme check" do
      mark = %{"type" => "link", "attrs" => %{"href" => "java\nscript:alert(1)"}}
      document = doc([paragraph([text("click", [mark])])])

      assert [message] = document |> Document.validate(schema()) |> messages()
      assert message =~ "control characters"
    end

    test "accepts relative and mailto URLs" do
      for href <- ["/posts/1", "#anchor", "mailto:a@b.c", "https://example.com"] do
        mark = %{"type" => "link", "attrs" => %{"href" => href}}
        document = doc([paragraph([text("click", [mark])])])

        assert {:ok, _} = Document.validate(document, schema())
      end
    end

    test "rejects marks on a block node" do
      document = doc([Map.put(paragraph([]), "marks", [%{"type" => "bold"}])])

      assert ["content[0].marks: marks are only allowed on inline nodes"] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects a mark the node does not allow" do
      document = doc([%{"type" => "code_block", "content" => [text("x", [%{"type" => "bold"}])]}])

      assert ["content[0].content[0].marks[0]: mark \"bold\" is not allowed on this node"] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects content that does not match the expression" do
      document = doc([%{"type" => "bullet_list", "content" => [paragraph([])]}])

      assert [message] = document |> Document.validate(schema()) |> messages()
      assert message =~ "does not match the content expression \"list_item+\""
    end

    test "rejects content on a leaf node" do
      document = doc([paragraph([%{"type" => "hard_break", "content" => [text("x")]}])])

      assert ["content[0].content[0].content: hard_break cannot hold content"] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects empty and non-string text" do
      assert ["content[0].content[0].text: must not be empty"] =
               doc([paragraph([%{"type" => "text", "text" => ""}])])
               |> Document.validate(schema())
               |> messages()

      assert ["content[0].content[0].text: must be a string"] =
               doc([paragraph([%{"type" => "text", "text" => 42}])])
               |> Document.validate(schema())
               |> messages()
    end

    test "rejects text on a node that is not a text node" do
      document = doc([Map.put(paragraph([]), "text", "smuggled")])

      assert ["content[0].text: only a text node may carry text"] =
               document |> Document.validate(schema()) |> messages()
    end

    test "rejects a document whose root is not the top node" do
      assert ["document must be a doc, got paragraph"] =
               paragraph([]) |> Document.validate(schema()) |> messages()
    end

    test "rejects a non-map document" do
      assert ["expected an object"] = "hello" |> Document.validate(schema()) |> messages()
    end

    test "reports every error rather than stopping at the first" do
      document =
        doc([
          %{"type" => "heading", "attrs" => %{"level" => 9}, "content" => []},
          %{"type" => "script"}
        ])

      assert [_, _] = messages(Document.validate(document, schema()))
    end
  end

  describe "to_text/2" do
    test "extracts text with one break per block" do
      document =
        doc([
          paragraph([text("first")]),
          paragraph([text("se"), %{"type" => "hard_break"}, text("cond")]),
          %{"type" => "blockquote", "content" => [paragraph([text("quoted")])]}
        ])

      assert Document.to_text(document, schema()) == "first\nse\ncond\nquoted"
    end

    test "ignores leaf nodes with nothing to say" do
      document = doc([paragraph([%{"type" => "image", "attrs" => %{"src" => "/a.png"}}])])

      assert Document.to_text(document, schema()) == ""
    end
  end

  describe "hostile input" do
    test "rejects a document nested past the depth limit" do
      deep =
        Enum.reduce(1..200, paragraph([text("bottom")]), fn _, inner ->
          %{"type" => "blockquote", "content" => [inner]}
        end)

      assert [message] = doc([deep]) |> Document.validate(schema()) |> messages()
      assert message =~ "nested more than 100 levels deep"
    end

    test "validating a deep document stays fast" do
      # Error paths used to be rebuilt at every level, which made validation
      # quadratic in depth: 2000 levels took 141 ms and 6000 took 1660 ms.
      deep =
        Enum.reduce(1..90, paragraph([text("bottom")]), fn _, inner ->
          %{"type" => "blockquote", "content" => [inner]}
        end)

      {microseconds, {:ok, _}} = :timer.tc(fn -> Document.validate(doc([deep]), schema()) end)

      assert microseconds < 100_000
    end
  end

  describe "error ordering" do
    test "errors come out in document order" do
      document =
        doc([
          %{"type" => "heading", "attrs" => %{"level" => 9}, "content" => []},
          %{"type" => "script"}
        ])

      assert [
               "content[0].attrs.level: must be one of [1, 2, 3, 4, 5, 6]",
               "content[1]: unknown node type \"script\""
             ] = messages(Document.validate(document, schema()))
    end

    test "the root error comes first" do
      document = %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => ""}]}

      assert [
               "document must be a doc, got paragraph",
               "content[0].text: must not be empty"
             ] = messages(Document.validate(document, schema()))
    end
  end

  describe "to_text/2 edge cases" do
    test "keeps blank blocks, dropping only the last block terminator" do
      document = doc([paragraph([text("a")]), paragraph([]), paragraph([])])

      assert Document.to_text(document, schema()) == "a\n\n"
    end

    test "does not crash on a text node missing its text" do
      assert Document.to_text(doc([paragraph([%{"type" => "text"}])]), schema()) == ""
    end

    test "honours a custom text node's :to_text" do
      schema =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [content: "inline*", group: "block"],
            text: [group: "inline", inline: true, text: true, to_text: "REDACTED"]
          ]
        )

      document = doc([paragraph([text("secret")])])

      assert Document.to_text(document, schema) == "REDACTED"
    end
  end

  describe "error accumulation" do
    test "many failing siblings stay linear" do
      # Appending to the growing accumulator made this quadratic: 4000 bad
      # children cost 40.8 ms and 8000 cost 148 ms.
      document = doc(List.duplicate(%{"type" => "script"}, 8000))

      {microseconds, {:error, errors}} =
        :timer.tc(fn -> Document.validate(document, schema()) end)

      assert length(errors) == 8000
      assert microseconds < 100_000
    end
  end

  describe "to_text/2 on mixed content" do
    test "a node mixing inline and block children keeps its separator" do
      schema =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            caption: [content: "inline* block*", group: "block"],
            paragraph: [content: "inline*", group: "block"],
            text: [group: "inline", inline: true, text: true]
          ]
        )

      document =
        doc([
          %{
            "type" => "caption",
            "content" => [
              %{"type" => "text", "text" => "lead"},
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "body"}]}
            ]
          }
        ])

      assert Document.to_text(document, schema) == "lead\nbody"
    end
  end
end
