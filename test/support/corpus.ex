defmodule Coelho.Test.Corpus do
  @moduledoc false
  # The documents whose *bytes* are promised, and the schemas they are
  # promised under.
  #
  # Properties say a document normalises the same way twice. Nothing said
  # that it normalises the same way this month as last month — and what a
  # database holds, an ETag compares and a signature covers is exactly that.
  # The fixture beside this module is the answer: source documents with the
  # canonical form, the hash, the rendered HTML and the extracted text they
  # produced, committed, so a change to any of them arrives as a diff to read
  # rather than as a page that stopped matching in production.

  alias Coelho.Schema

  @path Path.expand("../fixtures/corpus.json", __DIR__)
  @sources Path.expand("../../priv/corpus/sources.exs", __DIR__)

  def path, do: @path
  def sources_path, do: @sources

  @doc "The source documents, evaluated. What the fixture is supposed to be about."
  def sources, do: @sources |> Code.eval_file() |> elem(0)

  @doc "The schemas the corpus is written against, by the name each entry gives."
  def schemas do
    %{
      "default" => Schema.default(),
      "extended" => extended()
    }
  end

  # An application's schema, with the three shapes an application adds: a
  # mark the browser draws from its declaration, a void node standing for
  # something the page substitutes, and a node with a class of its own.
  defp extended do
    Schema.extend(Schema.default(),
      nodes: [
        variable: [
          group: "inline",
          inline: true,
          void: true,
          attrs: [
            name: [required: true, validate: {:one_of, ~w(number customer)}],
            label: [default: nil, validate: {:nullable, :string}]
          ],
          class: "variable",
          render: {"span", [{"data-variable", ""}]},
          editor_text: :label
        ],
        callout: [
          content: "block+",
          group: "block",
          class: "callout",
          render: {"aside", []},
          parse: ["aside"]
        ]
      ],
      marks: [highlight: [class: "hl", render: {"mark", []}]]
    )
  end

  @doc "The context the corpus renders with, so an attachment resolves the same way every time."
  def context do
    %{resolve: %{"kept" => "/attachments/kept"}}
  end

  def read, do: @path |> File.read!() |> JSON.decode!()

  @doc """
  The fixture as text: one entry per line inside the array.

  `JSON.encode!` of the whole list is one line of twelve thousand characters,
  and a regeneration then shows as one changed line — which is the review
  this file exists to make possible, not made possible.
  """
  def encode(entries), do: "[\n" <> Enum.map_join(entries, ",\n", &JSON.encode!/1) <> "\n]\n"
end
