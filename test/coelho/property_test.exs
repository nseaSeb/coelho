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

  defp collect_text(%{"type" => "text", "text" => text}), do: text

  defp collect_text(node) when is_map(node) do
    node |> Map.get("content", []) |> Enum.map_join(&collect_text/1)
  end
end
