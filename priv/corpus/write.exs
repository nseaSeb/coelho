# Writes the corpus fixture from its sources. Run it deliberately:
#
#     MIX_ENV=test mix run priv/corpus/write.exs
#
# and read the diff. Every line it changes is a change to bytes somebody
# downstream may be comparing — a stored hash, an ETag, a rendered page held
# beside its previous revision. That is the whole point of the file existing.

alias Coelho.Test.Corpus

schemas = Corpus.schemas()

entries =
  Corpus.sources()
  |> Enum.map(fn entry ->
    schema = Map.fetch!(schemas, entry.schema)

    validated =
      case Coelho.Document.validate(entry.document, schema) do
        {:ok, document} ->
          document

        {:error, errors} ->
          # Named, because a bare match failure here says "no match of right
          # hand side value" about one of fifteen documents and leaves the
          # reader to find out which.
          raise "#{entry.name} does not validate against the #{entry.schema} schema: " <>
                  inspect(errors)
      end

    %{
      "name" => entry.name,
      "schema" => entry.schema,
      "document" => entry.document,
      "canonical" => Coelho.Document.canonical(validated),
      "hash" => Coelho.hash(validated),
      "html" => Coelho.to_html(validated, schema, context: Corpus.context()),
      "inline_html" => Coelho.to_inline_html(validated, schema, context: Corpus.context()),
      "text" => Coelho.to_text(validated, schema)
    }
  end)

File.write!(Corpus.path(), Corpus.encode(entries))

IO.puts("wrote #{length(entries)} entries to #{Corpus.path()}")
