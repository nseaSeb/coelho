defmodule Coelho.DocumentTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Schema}
  alias Coelho.Document.Error

  doctest Coelho.Document

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

    test "leaves out an optional attribute that is at its schema default" do
      document = doc([%{"type" => "heading", "content" => [text("Title")]}])

      assert {:ok, normalised} = Document.validate(document, schema())
      refute Map.has_key?(hd(normalised["content"]), "attrs")
    end

    test "leaves out an attribute written out at its schema default" do
      spelled = doc([%{"type" => "heading", "attrs" => %{"level" => 1}, "content" => []}])
      implied = doc([%{"type" => "heading", "content" => []}])

      assert {:ok, normalised} = Document.validate(spelled, schema())
      assert {:ok, ^normalised} = Document.validate(implied, schema())
      refute Map.has_key?(hd(normalised["content"]), "attrs")
    end

    test "keeps an explicit attribute" do
      document =
        doc([%{"type" => "heading", "attrs" => %{"level" => 3}, "content" => [text("T")]}])

      assert {:ok, normalised} = Document.validate(document, schema())
      assert [%{"attrs" => %{"level" => 3}}] = normalised["content"]
    end

    test "rejects what is not a document at all, without raising" do
      for value <- [nil, "", 42, [], "not a document"] do
        assert {:error, [%Error{path: [], message: "expected an object"}]} =
                 Document.validate(value, schema())
      end
    end

    test "rejects the empty map for the reason it is not a document" do
      assert {:error, [%Error{path: [], message: ~s(missing "type")}]} =
               Document.validate(%{}, schema())
    end

    test "rejects an unknown node type" do
      assert ["content[0]: unknown node type \"script\""] =
               doc([%{"type" => "script"}]) |> Document.validate(schema()) |> messages()
    end

    test "rejects an unknown attribute" do
      document = doc([%{"type" => "paragraph", "attrs" => %{"onclick" => "x"}, "content" => []}])

      assert ["content[0].attrs.onclick: unknown attribute \"onclick\""] =
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

      document = doc([deep])
      # Measured cold, the first call pays for loading and JIT-compiling the
      # module, which has nothing to do with what is being measured.
      Document.validate(document, schema())
      {microseconds, {:ok, _}} = :timer.tc(fn -> Document.validate(document, schema()) end)

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
      # children cost 40.8 ms and 8000 cost 148 ms, which extrapolates to
      # about 2.4 s at the size below. Linear, it measures 49 ms — so the
      # budget is wide enough to survive a cold, loaded machine and still far
      # under what quadratic would cost.
      # The node bound would refuse this document before counting a single
      # error, and what is under test here is the counting.
      schema = Schema.extend(schema(), limits: [max_nodes: :infinity])
      document = doc(List.duplicate(%{"type" => "script"}, 32_000))

      Document.validate(doc(List.duplicate(%{"type" => "script"}, 100)), schema)

      {microseconds, {:error, errors}} =
        :timer.tc(fn -> Document.validate(document, schema) end)

      assert length(errors) == 32_000
      assert microseconds < 1_000_000
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

  describe "memory" do
    test "a validated document does not pin the payload it was parsed from" do
      # Binaries over 64 bytes live off the process heap, and a sub-binary of
      # one keeps the whole parent alive. Every string in a freshly decoded
      # document is such a sub-binary, and the document outlives the payload:
      # it goes into socket assigns, a changeset, a row.
      long = String.duplicate("a", 500)

      payload =
        JSON.encode!(
          doc([
            paragraph([text(String.duplicate("x", 400_000))]),
            paragraph([
              text(long, [%{"type" => "link", "attrs" => %{"href" => "/" <> long}}])
            ])
          ])
        )

      {:ok, document} = payload |> JSON.decode!() |> Document.validate(schema())

      [_, %{"content" => [%{"text" => kept, "marks" => [%{"attrs" => %{"href" => href}}]}]}] =
        document["content"]

      assert byte_size(kept) == 500
      assert :binary.referenced_byte_size(kept) == byte_size(kept)
      assert :binary.referenced_byte_size(href) == byte_size(href)
    end

    test "a string that is already whole is not copied" do
      # Copying every large string would be its own waste, so only sub-binaries
      # are copied.
      whole = String.duplicate("a", 500)
      document = doc([paragraph([text(whole)])])

      {:ok, validated} = Document.validate(document, schema())
      [%{"content" => [%{"text" => kept}]}] = validated["content"]

      assert :erts_debug.same(kept, whole)
    end
  end

  describe "adjacent text" do
    test "runs carrying the same marks are merged" do
      document =
        doc([
          paragraph([
            text("a"),
            text("b", [%{"type" => "bold"}]),
            text("c", [%{"type" => "bold"}])
          ])
        ])

      assert {:ok, normalised} = Document.validate(document, schema())
      assert [%{"content" => [_, %{"text" => "bc"}]}] = normalised["content"]
    end

    test "runs carrying different marks stay apart" do
      document = doc([paragraph([text("a", [%{"type" => "bold"}]), text("b")])])

      assert {:ok, normalised} = Document.validate(document, schema())
      assert [%{"content" => [%{"text" => "a"}, %{"text" => "b"}]}] = normalised["content"]
    end
  end

  describe "marks are a set" do
    test "the same mark twice is normalised away, not rejected" do
      marks = [%{"type" => "bold"}, %{"type" => "bold"}, %{"type" => "italic"}]
      document = doc([paragraph([text("x", marks)])])

      assert {:ok, normalised} = Document.validate(document, schema())

      assert [%{"content" => [%{"marks" => kept}]}] = normalised["content"]
      assert kept == [%{"type" => "bold"}, %{"type" => "italic"}]
    end
  end
end
