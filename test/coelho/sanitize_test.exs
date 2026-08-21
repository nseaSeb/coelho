defmodule Coelho.SanitizeTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Schema}

  defp schema, do: Schema.default()

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp sanitize(document), do: Document.sanitize(document, schema())

  defp valid?(document), do: match?({:ok, _}, Document.validate(document, schema()))

  describe "what it keeps" do
    test "a document that already validates comes back normalised and unchanged" do
      {:ok, document} = Document.validate(doc([paragraph([text("hello")])]), schema())

      assert sanitize(document) == document
    end

    test "sanitising twice is sanitising once" do
      hostile =
        doc([
          %{"type" => "script", "content" => [text("x")]},
          paragraph([text("kept", [%{"type" => "evil"}])])
        ])

      once = sanitize(hostile)

      assert sanitize(once) == once
    end
  end

  describe "what it removes" do
    test "a key the schema does not know" do
      document = doc([Map.put(paragraph([text("kept")]), "onclick", "alert(1)")])

      assert %{"content" => [%{"type" => "paragraph"} = kept]} = sanitize(document)
      refute Map.has_key?(kept, "onclick")
      assert Document.to_text(sanitize(document), schema()) == "kept"
    end

    test "an attribute failing its validator, leaving the schema default" do
      document =
        doc([%{"type" => "heading", "attrs" => %{"level" => 99}, "content" => [text("T")]}])

      sanitized = sanitize(document)

      assert Coelho.to_html(sanitized) == "<h1>T</h1>"
    end

    test "a link whose href the browser would execute, keeping the text" do
      document =
        doc([
          paragraph([
            text("click", [%{"type" => "link", "attrs" => %{"href" => "javascript:alert(1)"}}])
          ])
        ])

      assert Coelho.to_html(sanitize(document)) == "<p>click</p>"
    end

    test "a mark the schema has never heard of, keeping the text" do
      document = doc([paragraph([text("x", [%{"type" => "blink"}])])])

      assert Coelho.to_html(sanitize(document)) == "<p>x</p>"
    end

    test "a node whose type is unknown, and the text inside it" do
      document =
        doc([%{"type" => "script", "content" => [text("alert(1)")]}, paragraph([text("kept")])])

      assert Coelho.to_html(sanitize(document)) == "<p>kept</p>"
    end

    test "a node whose content cannot satisfy its content expression" do
      document = doc([%{"type" => "bullet_list", "content" => []}, paragraph([text("kept")])])

      assert Coelho.to_html(sanitize(document)) == "<p>kept</p>"
    end

    test "a mark sitting where the node forbids every mark" do
      document =
        doc([%{"type" => "code_block", "content" => [text("x", [%{"type" => "bold"}])]}])

      assert Coelho.to_html(sanitize(document)) == "<pre><code>x</code></pre>"
    end
  end

  describe "a repair the error path cannot express" do
    test "a node missing a required attribute goes, and its siblings stay" do
      document =
        doc([paragraph([text("keep me"), %{"type" => "image", "attrs" => %{"alt" => "no src"}}])])

      assert Coelho.to_html(sanitize(document)) == "<p>keep me</p>"
    end

    test "and it goes even when it also sits where the schema does not allow it" do
      document =
        doc([paragraph([text("keep me")]), %{"type" => "image", "attrs" => %{"alt" => "no src"}}])

      assert Coelho.to_html(sanitize(document)) == "<p>keep me</p>"
    end

    test "the same for an attachment with no key" do
      document =
        doc([
          %{"type" => "attachment", "attrs" => %{"filename" => "a.pdf"}},
          paragraph([text("kept")])
        ])

      assert Coelho.to_html(sanitize(document)) == "<p>kept</p>"
    end

    test "one stray attribute does not cost the node its others" do
      document =
        doc([
          %{
            "type" => "heading",
            "attrs" => %{"level" => 3, "onclick" => "x"},
            "content" => [text("T")]
          }
        ])

      assert Coelho.to_html(sanitize(document)) == "<h3>T</h3>"
    end
  end

  describe "what it falls back to" do
    test "a document that is not a document at all" do
      for hostile <- [nil, "", %{}, [], 42, %{"type" => "script"}] do
        sanitized = sanitize(hostile)

        assert valid?(sanitized)
        assert Document.to_text(sanitized, schema()) == ""
      end
    end

    test "a tree of nothing the schema knows" do
      hostile = doc(List.duplicate(%{"type" => "script"}, 10))

      assert sanitize(hostile) == Coelho.empty(schema())
    end
  end

  describe "the postcondition" do
    test "whatever goes in, what comes out validates" do
      hostile = [
        doc([paragraph([%{"type" => "text"}])]),
        doc([paragraph("not a list")]),
        doc([paragraph([Map.put(text("x"), "marks", "not a list")])]),
        doc([%{"type" => "paragraph", "attrs" => "not a map", "content" => []}]),
        doc([%{"type" => "list_item", "content" => [paragraph([text("x")])]}]),
        %{"type" => "paragraph", "content" => [text("a top node in the wrong place")]}
      ]

      for document <- hostile do
        assert valid?(sanitize(document)), "did not repair #{inspect(document)}"
      end
    end
  end

  describe "schema versions" do
    test "a document from another version is repaired, not emptied" do
      v2 = Schema.extend(Schema.default(), version: 2)
      v1_document = Map.put(doc([paragraph([text("kept")])]), "schema_version", 1)

      sanitized = Document.sanitize(v1_document, v2)

      assert sanitized["schema_version"] == 2
      assert Document.to_text(sanitized, v2) == "kept"
    end

    test "and what the new schema no longer knows is what goes" do
      v2 =
        Schema.default()
        |> Schema.restrict(nodes: [:paragraph])
        |> Schema.extend(version: 2)

      v1_document =
        Map.put(
          doc([%{"type" => "heading", "content" => [text("gone")]}, paragraph([text("kept")])]),
          "schema_version",
          1
        )

      assert Document.to_text(Document.sanitize(v1_document, v2), v2) == "kept"
    end
  end

  describe "limits" do
    defp bounded(limits), do: Schema.extend(Schema.default(), limits: limits)

    test "a document with too many nodes is refused, not counted out" do
      document = doc(List.duplicate(paragraph([text("x")]), 20))

      assert {:error, [error]} = Document.validate(document, bounded(max_nodes: 10))
      assert error.message =~ "more than 10 nodes"
    end

    test "a document nested deeper than the bound is refused" do
      deep =
        Enum.reduce(1..10, paragraph([text("x")]), fn _, acc ->
          %{"type" => "blockquote", "content" => [acc]}
        end)

      assert {:error, [error]} = Document.validate(doc([deep]), bounded(max_depth: 5))
      assert error.message =~ "more than 5 levels"
    end

    test "a bound on text counts characters, not bytes" do
      # Seven accented letters are fourteen bytes. Refusing on the byte count
      # would reject every document that is not ASCII well under its bound.
      document = doc([paragraph([text(String.duplicate("é", 7))])])

      assert {:ok, _} = Document.validate(document, bounded(max_text_length: 10))
      assert {:error, [_]} = Document.validate(document, bounded(max_text_length: 6))
    end

    test "a document with more text than the bound is refused" do
      document = doc([paragraph([text(String.duplicate("a", 50))])])

      assert {:error, [error]} = Document.validate(document, bounded(max_text_length: 10))
      assert error.message =~ "more than 10 characters"
    end

    test "the bound counts the whole document, not one node" do
      document = doc(List.duplicate(paragraph([text("aaaaa")]), 4))

      assert {:error, [_]} = Document.validate(document, bounded(max_text_length: 10))
      assert {:ok, _} = Document.validate(document, bounded(max_text_length: 20))
    end

    test ":infinity lifts a bound" do
      document = doc(List.duplicate(paragraph([text("x")]), 50))

      assert {:ok, _} = Document.validate(document, bounded(max_nodes: :infinity))
    end

    test "the shipped bounds are far above a document anyone writes" do
      assert Schema.default().limits == Schema.default_limits()
      assert Schema.default_limits().max_nodes == 10_000
    end

    test "sanitising a document over the bound gives the empty document" do
      document = doc(List.duplicate(paragraph([text("x")]), 20))

      assert Document.sanitize(document, bounded(max_nodes: 10)) ==
               Coelho.empty(bounded(max_nodes: 10))
    end
  end
end
