defmodule Coelho.InlineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp inline(document, opts \\ []) do
    {:ok, document} = Coelho.validate(document)
    Coelho.to_inline_html(document, opts)
  end

  # Anything the HTML spec will not let sit inside a `<p>` or a `<span>`. The
  # guarantee is one assertion rather than thirty cases: whatever the
  # document held, none of these came out.
  @block ~w(address article aside blockquote details dialog div dl dt dd
            fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header
            hgroup hr li main nav ol p pre section table tbody td tfoot th
            thead tr ul)

  defp block_tags(html) do
    ~r/<\/?([a-zA-Z][a-zA-Z0-9]*)/
    |> Regex.scan(html)
    |> Enum.map(fn [_match, tag] -> String.downcase(tag) end)
    |> Enum.filter(&(&1 in @block))
    |> Enum.uniq()
  end

  describe "the guarantee" do
    test "no block element survives, whatever the document held" do
      document =
        doc([
          paragraph([text("un")]),
          %{"type" => "heading", "attrs" => %{"level" => 2}, "content" => [text("titre")]},
          %{"type" => "horizontal_rule"},
          %{
            "type" => "bullet_list",
            "content" => [
              %{"type" => "list_item", "content" => [paragraph([text("puce")])]}
            ]
          },
          %{"type" => "code_block", "content" => [text("du code")]},
          %{"type" => "blockquote", "content" => [paragraph([text("cité")])]},
          %{"type" => "attachment", "attrs" => %{"key" => "k", "filename" => "plan.pdf"}}
        ])

      assert block_tags(inline(document)) == []
    end

    property "and none survives a document the schema accepts" do
      check all(document <- Coelho.Test.Documents.document(), max_runs: 200) do
        assert block_tags(Coelho.to_inline_html(document)) == []
      end
    end
  end

  describe "what it keeps" do
    test "marks, which are inline" do
      document = doc([paragraph([text("gras", [%{"type" => "bold"}])])])

      assert inline(document) == "<strong>gras</strong>"
    end

    test "a link, an image and a break" do
      document =
        doc([
          paragraph([
            text("voir", [%{"type" => "link", "attrs" => %{"href" => "/a"}}]),
            %{"type" => "hard_break"},
            %{"type" => "image", "attrs" => %{"src" => "/a.png"}}
          ])
        ])

      assert inline(document) == ~s(<a href="/a">voir</a><br><img src="/a.png">)
    end

    test "the words of a block that lost its tag" do
      document = doc([%{"type" => "code_block", "content" => [text("du code")]}])

      assert inline(document) == "du code"
    end

    test "the link of an attachment that resolves, because <a> is inline" do
      # A card excerpt that lost the download link would be losing the point
      # of showing the attachment at all.
      document =
        doc([%{"type" => "attachment", "attrs" => %{"key" => "k", "filename" => "plan.pdf"}}])

      {:ok, document} = Coelho.validate(document)

      assert Coelho.to_inline_html(document, context: %{resolve: &("/files/" <> &1)}) ==
               ~s(<a href="/files/k">plan.pdf</a>)
    end

    test "an empty caption adds nothing, not a trailing space" do
      document =
        doc([
          %{
            "type" => "attachment",
            "attrs" => %{"key" => "k", "filename" => "a.pdf", "caption" => ""}
          },
          paragraph([text("x")])
        ])

      refute inline(document) =~ "</span>  "
      assert inline(document) =~ "</span> x"
    end

    test "an attachment says what it is inline, rather than contributing nothing" do
      # `blank?/2` counts an attachment as content. Rendering nothing for it
      # here would be the two answering differently about the same document.
      document =
        doc([
          %{
            "type" => "attachment",
            "attrs" => %{"key" => "k", "filename" => "plan.pdf", "caption" => "Le plan"}
          }
        ])

      refute Coelho.blank?(document)

      assert inline(document) ==
               ~s(<span class="coelho-attachment-missing">plan.pdf</span> Le plan)
    end

    test "and says so with an element, so it cannot be dropped as empty" do
      # `filename` accepts `""` and so does `key`. Contributing bare text
      # would make an attachment with neither vanish when the blocks are
      # joined — out of a document `blank?/2` calls non-blank.
      document =
        doc([
          paragraph([text("un")]),
          %{"type" => "attachment", "attrs" => %{"key" => "k", "filename" => ""}},
          paragraph([text("deux")])
        ])

      refute Coelho.blank?(document)
      assert inline(document) =~ "coelho-attachment-missing"
      assert inline(document) =~ ">k<"
    end
  end

  describe "what the caller can override" do
    test "a node's render, including the text node's" do
      # The block renderer goes out of its way not to short circuit on text
      # so that no node is the one a caller cannot reach. Inline rendering
      # advertises the same options and has to keep the same promise.
      document = doc([paragraph([text("hi")])])
      opts = [nodes: %{text: fn _node, inner -> ["[", inner, "]"] end}]

      assert Coelho.to_html(elem(Coelho.validate(document), 1), opts) == "<p>[hi]</p>"
      assert inline(document, opts) == "[hi]"
    end

    test "a block's, which unwrapping would otherwise have swallowed" do
      # Overriding `attachment` is the natural thing for an application that
      # resolves its own URLs, and it was being ignored.
      document =
        doc([%{"type" => "attachment", "attrs" => %{"key" => "k", "filename" => "a.pdf"}}])

      assert inline(document, nodes: %{attachment: fn _node, _inner -> "OVERRIDE" end}) ==
               "OVERRIDE"
    end

    test "and a mark's" do
      document = doc([paragraph([text("x", [%{"type" => "bold"}])])])

      assert inline(document, marks: %{bold: {"b", []}}) == "<b>x</b>"
    end
  end

  describe "the separator" do
    test "goes between blocks and nowhere else" do
      run_on =
        doc([
          paragraph([text("un"), text(" gras", [%{"type" => "bold"}])]),
          paragraph([text("deux")])
        ])

      assert inline(run_on) == "un<strong> gras</strong> deux"
    end

    test "is a space by default, because the other mistake breaks a layout" do
      document = doc([paragraph([text("un")]), paragraph([text("deux")])])

      assert inline(document) == "un deux"
      assert inline(document, separator: :br) == "un<br>deux"
    end

    test "does not follow a block that contributed nothing" do
      # A horizontal rule has no inline form at all. Leaving its separator
      # behind would put two of them between the blocks either side.
      document =
        doc([paragraph([text("un")]), %{"type" => "horizontal_rule"}, paragraph([text("deux")])])

      assert inline(document) == "un deux"
    end

    test "one of your own is escaped, because it may have come from data" do
      document = doc([paragraph([text("un")]), paragraph([text("deux")])])

      assert inline(document, separator: " — ") == "un — deux"
      assert inline(document, separator: "<b>") == "un&lt;b&gt;deux"
      assert inline(document, separator: {:safe, "<br>"}) == "un<br>deux"
    end

    test "and anything else is a mistake worth naming" do
      document = doc([paragraph([text("un")])])

      assert_raise ArgumentError, ~r/separator must be/, fn ->
        inline(document, separator: :newline)
      end
    end
  end

  describe "the safe form" do
    test "needs no raw/1, like the block one" do
      {:ok, document} = Coelho.validate(doc([paragraph([text("a & b")])]))

      assert {:safe, iodata} = Coelho.to_safe_inline_html(document)
      assert IO.iodata_to_binary(iodata) == "a &amp; b"
    end

    test "renders nothing for a document that is not there" do
      assert Coelho.to_safe_inline_html(nil) == {:safe, []}
      assert Coelho.to_inline_html(nil) == ""
    end
  end
end
