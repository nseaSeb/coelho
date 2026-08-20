defmodule Coelho.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Coelho.{Document, Render, Schema}

  defp schema, do: Schema.default()

  # -- Generators -----------------------------------------------------------

  # Not `uniq_list_of`: it gives up after ten consecutive duplicates, and
  # there are only five marks to draw from, so the run failed on the seeds
  # that happened to repeat — intermittently, and never where it was looked
  # for. Drawing a list and taking it apart cannot run out of tries.
  defp text_node do
    gen all(
          text <- string(:printable, min_length: 1),
          drawn <- list_of(mark(), max_length: 3)
        ) do
      marks = Enum.uniq_by(drawn, & &1["type"])

      case marks do
        [] -> %{"type" => "text", "text" => text}
        marks -> %{"type" => "text", "text" => text, "marks" => marks}
      end
    end
  end

  defp plain_text_node do
    gen all(text <- string(:printable, min_length: 1)) do
      %{"type" => "text", "text" => text}
    end
  end

  defp mark do
    one_of([
      constant(%{"type" => "bold"}),
      constant(%{"type" => "italic"}),
      constant(%{"type" => "strike"}),
      constant(%{"type" => "code"}),
      gen all(path <- string(:alphanumeric, min_length: 1)) do
        %{"type" => "link", "attrs" => %{"href" => "/" <> path}}
      end
    ])
  end

  defp inline do
    one_of([
      text_node(),
      constant(%{"type" => "hard_break"}),
      gen all(src <- string(:alphanumeric, min_length: 1)) do
        %{"type" => "image", "attrs" => %{"src" => "/" <> src <> ".png"}}
      end
    ])
  end

  defp block do
    one_of([
      gen all(content <- list_of(inline(), max_length: 4)) do
        %{"type" => "paragraph", "content" => content}
      end,
      gen all(level <- integer(1..6), content <- list_of(text_node(), max_length: 3)) do
        %{"type" => "heading", "attrs" => %{"level" => level}, "content" => content}
      end,
      gen all(content <- list_of(plain_text_node(), max_length: 3)) do
        %{"type" => "code_block", "content" => content}
      end,
      constant(%{"type" => "horizontal_rule"})
    ])
  end

  defp document do
    gen all(content <- list_of(block(), min_length: 1, max_length: 5)) do
      %{"type" => "doc", "content" => content}
    end
  end

  # -- Properties -----------------------------------------------------------

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
    check all(document <- document()) do
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
