defmodule Coelho.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Coelho.{Document, Render, Schema}

  defp schema, do: Schema.default()

  # The generators live in `Coelho.Test.Documents`, shared with the inline
  # rendering property: two properties asking different questions of the same
  # shapes should be asking them of the same shapes.
  import Coelho.Test.Documents

  # -- Properties -----------------------------------------------------------

  # `escape/1` used to be five `String.replace/3` calls in a row, which is
  # what this compares against: the single pass that replaced them has to
  # answer exactly the same thing, including for text that escapes to itself
  # and is handed back rather than rebuilt.
  defp escape_in_five_passes(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  property "escaping in one pass says what escaping in five passes said" do
    check all(
            text <-
              StreamData.string(
                Enum.concat([~c"&<>\"'", ~c"aé \n\t", [0x1F600, 0x00E9, 0x4E2D]]),
                max_length: 60
              )
          ) do
      assert Render.escape(text) == escape_in_five_passes(text)
    end
  end

  property "a document built from the schema validates against it" do
    check all(document <- document()) do
      assert {:ok, _} = Document.validate(document, schema())
    end
  end

  property "normalisation is idempotent, so stored documents are canonical" do
    check all(document <- document()) do
      {:ok, once} = Document.validate(document, schema())
      {:ok, twice} = Document.validate(once, schema())

      assert once == twice
    end
  end

  property "rendering never lets text escape into markup" do
    check all(document <- document()) do
      {:ok, document} = Document.validate(document, schema())
      html = Render.to_html(document, schema())

      # Strip every element the schema is allowed to emit; whatever is left
      # is text, and must not contain a raw angle bracket or quote.
      remainder = String.replace(html, ~r|</?[a-z0-9]+(?: [a-z]+="[^"]*")*>|, "")

      refute remainder =~ ~r/[<>"]/
    end
  end

  property "plain text extraction only ever yields text the document holds" do
    # Without the attachment, whose spec carries a `:to_text` — the one
    # mechanism by which a node contributes something the document does not
    # hold as a text node, which is what that field exists for. Sharing the
    # generator with the inline property is what surfaced this: the premise
    # had always been narrower than the name.
    check all(document <- document([:attachment])) do
      {:ok, document} = Document.validate(document, schema())

      for line <- document |> Document.to_text(schema()) |> String.split("\n"),
          line != "" do
        assert String.contains?(collect_text(document), line) or line =~ "\n"
      end
    end
  end

  property "junk input is rejected rather than crashing" do
    check all(junk <- term()) do
      assert match?({:ok, _}, Document.validate(junk, schema())) or
               match?({:error, _}, Document.validate(junk, schema()))
    end
  end

  # -- What reaches the renderer without passing validation ------------------

  # `Coelho.HTML` has carried "no HTML raises, whatever it is" since the
  # import existed, because HTML plainly comes from outside. The renderer
  # reads two things that come from outside just as much and had no such
  # promise: a row written under whatever schema was in force when it was
  # stored, and a value handed back by a function the application wrote.
  # Every defect found in `attributes/1` lived in that gap.

  property "a row written under any schema at all still renders" do
    check all(document <- document(), value <- term()) do
      stored = corrupt_attrs(document, value)

      assert is_binary(Render.to_html(stored, schema()))
      assert is_binary(Render.to_inline_html(stored, schema()))
      assert is_binary(Document.to_text(stored, schema()))

      repaired = Document.sanitize(stored, schema())

      assert is_binary(Render.to_html(repaired, schema()))
      assert {:ok, _} = Document.validate(repaired, schema())
    end
  end

  property "an attribute a schema's own render hands back never raises, whatever it is" do
    check all(value <- term()) do
      assert is_binary(rendered_with_attr(value))
    end
  end

  # The invariant the `class` merge kept failing, in each of its directions:
  # a value that renders on its own has to still be there when a spec's
  # `:class` joins it. Two values do not accumulate, and both say so here
  # rather than in a comment: the empty string, which has nothing to add,
  # and a boolean, which is whether the attribute is written rather than
  # what it holds.
  property "a value that renders alone is still there beside a spec's class" do
    check all(value <- term()) do
      expected =
        case class_attribute(rendered_with_class(value, nil)) do
          {:value, ""} -> {:value, "note"}
          {:value, rendered} -> {:value, rendered <> " note"}
          :bare -> {:value, "note"}
          :absent -> {:value, "note"}
        end

      assert class_attribute(rendered_with_class(value, "note")) == expected
    end
  end

  test "a literal attribute the schema could not export is refused when it is built" do
    # Which is why the two properties above go through a function: this is a
    # gate, and it is the right one. A schema is exported to the browser as
    # JSON, so a literal it cannot encode is a schema that cannot be built —
    # said once, at boot, rather than on a page.
    assert_raise ErlangError, fn ->
      Schema.new(
        nodes: [
          doc: [content: "block+"],
          paragraph: [content: "text*", group: "block", render: {"p", [{"data-x", <<128>>}]}]
        ]
      )
    end
  end

  # -- Helpers ---------------------------------------------------------------

  # Every attribute of every node and mark set to the same term: what a
  # validator that has since been tightened would have let through, and what
  # no generator built from today's schema can produce.
  defp corrupt_attrs(node, value) when is_map(node) do
    node
    |> replace_attrs(value)
    |> update_list("content", &corrupt_attrs(&1, value))
    |> update_list("marks", &replace_attrs(&1, value))
  end

  defp replace_attrs(%{"attrs" => attrs} = node, value) when is_map(attrs) and attrs != %{} do
    %{node | "attrs" => Map.new(attrs, fn {name, _was} -> {name, value} end)}
  end

  defp replace_attrs(node, _value), do: node

  defp update_list(node, key, fun) do
    case Map.get(node, key) do
      list when is_list(list) -> Map.put(node, key, Enum.map(list, fun))
      _absent -> node
    end
  end

  defp document_of_one_paragraph, do: %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}

  defp rendered_with_attr(value), do: rendered_with("data-x", value, nil)

  defp rendered_with_class(value, class), do: rendered_with("class", value, class)

  # Through a function rather than as a literal in the declaration, because
  # the two are gated differently and the function is the one with no gate:
  # a literal is JSON encoded into the schema's fingerprint when the schema
  # is built, so a value that cannot be exported is refused there — see the
  # test below. What a function hands back at render time meets nothing.
  defp rendered_with(name, value, class) do
    paragraph =
      [content: "text*", group: "block", render: {"p", fn _node -> [{name, value}] end}] ++
        if class, do: [class: class], else: []

    built = Schema.new(nodes: [doc: [content: "block+"], paragraph: paragraph])

    Render.to_html(document_of_one_paragraph(), built)
  end

  # Read off the markup rather than through a parser: a parser answers the
  # same thing for a bare `class` as for `class="class"`, and the difference
  # between them is the whole point. A `"` cannot appear inside the value,
  # having been escaped on the way out.
  defp class_attribute(html) do
    case Regex.run(~r/<p class="([^"]*)"/, html) do
      [_match, rendered] -> {:value, rendered}
      nil -> if String.contains?(html, "<p class>"), do: :bare, else: :absent
    end
  end

  defp collect_text(%{"type" => "text", "text" => text}), do: text

  defp collect_text(node) when is_map(node) do
    node |> Map.get("content", []) |> Enum.map_join(&collect_text/1)
  end
end
