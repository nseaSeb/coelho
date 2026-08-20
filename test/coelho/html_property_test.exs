defmodule Coelho.HTMLPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Coelho.{Document, HTML, Render, Schema}

  # The import is the one door foreign input walks through: existing columns,
  # other editors, feeds, whatever someone pastes. Example-based tests cover
  # the shapes I thought of; these cover the ones I did not.

  defp schema, do: Schema.default()

  @tags ~w(p div span h1 h2 h3 ul ol li blockquote pre code strong b em i s a img br hr
           table tr td th section article figure figcaption script style template
           form input button svg iframe custom-element)

  @attributes [
    {"href", ["/a", "https://example.com", "javascript:alert(1)", "", "#x"]},
    {"src", ["/a.png", "https://example.com/a.png", "data:image/png;base64,xx", ""]},
    {"class", ["a", "b c"]},
    {"onclick", ["alert(1)"]},
    {"style", ["color:red"]},
    {"start", ["1", "3", "not a number"]},
    {"data-user-id", ["7", "abc"]}
  ]

  defp attribute do
    gen all({name, values} <- member_of(@attributes), value <- member_of(values)) do
      ~s( #{name}="#{value}")
    end
  end

  defp text do
    one_of([
      string(:printable, max_length: 12),
      constant("a & b"),
      constant("<not a tag"),
      constant("&amp;&lt;&#39;"),
      constant("   "),
      constant("\n\t "),
      constant("héllo"),
      constant("\u{E000}")
    ])
  end

  defp bare_tag do
    gen all(tag <- member_of(@tags)) do
      "<#{tag}>"
    end
  end

  defp fragment(0) do
    one_of([text(), bare_tag()])
  end

  defp fragment(depth) do
    one_of([
      text(),
      gen all(
            tag <- member_of(@tags),
            attributes <- list_of(attribute(), max_length: 2),
            children <- list_of(fragment(depth - 1), max_length: 3)
          ) do
        Enum.join(["<#{tag}#{Enum.join(attributes)}>", Enum.join(children), "</#{tag}>"])
      end,
      # Unclosed, because real clipboard payloads and real database columns
      # are full of those.
      bare_tag()
    ])
  end

  defp html do
    gen(all(fragments <- list_of(fragment(3), max_length: 4), do: Enum.join(fragments)))
  end

  property "no HTML raises, whatever it is" do
    check all(source <- html(), max_runs: 300) do
      # `{:ok, _} or {:error, _}` holds for anything at all, and imports twice
      # to say it. What is asserted is that the call returns rather than
      # raises, and that what comes back is one of the two shapes.
      assert elem(HTML.from_html(source, schema()), 0) in [:ok, :error]
    end
  end

  property "what comes out is a document the schema accepts" do
    check all(source <- html(), max_runs: 300) do
      case HTML.from_html(source, schema()) do
        {:ok, document} ->
          # Not "it validated once": the import runs validation itself, so
          # this asserts the stronger thing — that validating again changes
          # nothing, which is what makes the result canonical.
          assert {:ok, ^document} = Document.validate(document, schema())

        {:error, _errors} ->
          :ok
      end
    end
  end

  property "nothing the browser would execute survives the import" do
    check all(source <- html(), max_runs: 300) do
      with {:ok, document} <- HTML.from_html(source, schema()) do
        rendered = Render.to_html(document, schema())

        refute rendered =~ ~r/javascript:/i
        refute rendered =~ ~r/<script/i
        refute rendered =~ ~r/\son[a-z]+=/i
        refute rendered =~ "\u{E000}"
      end
    end
  end

  property "importing what was rendered gives the same document back" do
    check all(source <- html(), max_runs: 200) do
      with {:ok, document} <- HTML.from_html(source, schema()) do
        rendered = Render.to_html(document, schema())

        # The schema's own output is the one HTML the import must handle
        # exactly: anything else means a round trip through storage and
        # rendering slowly rewrites people's documents.
        assert {:ok, ^document} = HTML.from_html(rendered, schema())
      end
    end
  end
end
