defmodule Coelho.WalksTest do
  use ExUnit.Case, async: true

  alias Coelho.{Attachments, Document, Render, Schema}

  # Sixteen walks of a document live in this library, and the obvious question
  # is why they are not all written on `Render.reduce/4`, which is documented
  # as the fold to write one on. The answer is that they do not all promise
  # the same thing, and the difference is not a detail: a walk that raises
  # where it should tolerate takes down a page rendering a row written years
  # ago, and one that tolerates where it should raise hands a caller a
  # document nobody checked.
  #
  # So rather than one traversal, one test: the promises, pinned, so a walk
  # that changes its mind about them is caught here.

  defp schema, do: Schema.default()

  # A node this schema does not declare — a row written under a schema that
  # has since dropped it, or under an application's own that this deployment
  # no longer builds. Not a hostile document: an old one.
  defp foreign do
    %{
      "type" => "doc",
      "content" => [
        %{"type" => "marquee", "content" => [%{"type" => "text", "text" => "old"}]},
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "kept"}]}
      ]
    }
  end

  describe "the walks a stored document reaches" do
    test "sanitising repairs it rather than refusing it" do
      document = Document.sanitize(foreign(), schema())

      assert {:ok, ^document} = Document.validate(document, schema())
      assert Document.to_text(document, schema()) =~ "kept"
    end

    test "validating reports on it rather than raising" do
      assert {:error, [_ | _]} = Document.validate(foreign(), schema())
    end

    test "collecting attachment keys answers rather than raising" do
      # This one decides what gets deleted: raising here would leave an
      # application unable to tidy up, and answering wrongly would delete
      # bytes a document still points at.
      assert Attachments.keys(foreign(), schema()) == []
    end

    test "extracting text and counting it answer rather than raising" do
      # The extraction asks the schema what a node contributes, so a node it
      # does not know contributes nothing; the count asks the document alone,
      # which is what makes it the same number the browser shows.
      assert Document.to_text(foreign(), schema()) == "\nkept"
      assert Document.text_length(foreign()) == 7
    end
  end

  describe "the walks that trust the document they were handed" do
    test "rendering raises on a node the schema does not declare" do
      assert_raise ArgumentError, ~r/marquee/, fn -> Render.to_html(foreign(), schema()) end
    end

    test "the fold raises too, which is why the walks above are not written on it" do
      assert_raise ArgumentError, ~r/marquee/, fn ->
        Render.reduce(foreign(), schema(), %{node: fn _node, children -> children end})
      end
    end

    test "and both are fine with what sanitising gives back" do
      document = Document.sanitize(foreign(), schema())

      assert Render.to_html(document, schema()) =~ "kept"
      assert Render.reduce(document, schema(), %{node: fn _node, children -> children end})
    end
  end
end
