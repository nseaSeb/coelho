defmodule Coelho.CorpusTest do
  use ExUnit.Case, async: true

  alias Coelho.Test.Corpus

  # What a property cannot say: that a document normalises the same way this
  # month as it did last month. `canonical_test.exs` pins the rules — marks
  # sorted, defaults dropped, adjacent runs merged — and a change to any of
  # them keeps satisfying every rule while producing different bytes.
  #
  # Different bytes are what a stored hash compares, what an ETag is built
  # from, and what a diff between two revisions of a page shows. So the bytes
  # themselves are committed, and this reads them back.
  #
  # A failure here is not necessarily a bug. It is a question: was this
  # change meant, and does the application that stored the old answer need
  # telling? When it was meant:
  #
  #     MIX_ENV=test mix run priv/corpus/write.exs
  #
  # and the diff is the report.

  @entries Corpus.read()
  @external_resource Corpus.path()
  @external_resource Corpus.sources_path()

  test "the fixture is the sources, and nothing else" do
    # Nothing else ties the two together: the tests below read the fixture,
    # and CI never runs the writer. Edit a source and forget to regenerate,
    # and the suite goes on asserting the old bytes of the old documents
    # while the diff being reviewed shows new ones — the file would prove
    # what it is no longer about.
    sources = Corpus.sources()

    assert Enum.map(@entries, & &1["name"]) == Enum.map(sources, & &1.name)

    for {entry, source} <- Enum.zip(@entries, sources) do
      assert entry["schema"] == source.schema
      assert entry["document"] == source.document
    end
  end

  for entry <- @entries do
    @entry entry

    describe "#{entry["name"]}" do
      setup do
        schema = Map.fetch!(Corpus.schemas(), @entry["schema"])
        {:ok, document} = Coelho.Document.validate(@entry["document"], schema)

        %{schema: schema, document: document}
      end

      test "normalises to the bytes it did", %{document: document} do
        assert Coelho.Document.canonical(document) == @entry["canonical"]
      end

      test "hashes to what was stored", %{document: document} do
        # The one promise with no way back: an application that kept this
        # number as proof of what somebody agreed to cannot be asked to
        # recompute it.
        assert Coelho.hash(document) == @entry["hash"]
      end

      test "renders the same page", %{document: document, schema: schema} do
        assert Coelho.to_html(document, schema, context: Corpus.context()) == @entry["html"]

        assert Coelho.to_inline_html(document, schema, context: Corpus.context()) ==
                 @entry["inline_html"]
      end

      test "extracts the same text", %{document: document, schema: schema} do
        assert Coelho.to_text(document, schema) == @entry["text"]
      end

      test "is unchanged by validating it again", %{document: document, schema: schema} do
        # Normalisation is idempotent, so a stored document read back and
        # revalidated is the same document — including its hash.
        assert {:ok, ^document} = Coelho.Document.validate(document, schema)
      end
    end
  end
end
