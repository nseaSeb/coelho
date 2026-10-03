defmodule Coelho.MarkdownTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Coelho.{Document, Markdown, Schema}

  import Coelho.Test.Documents

  defp schema, do: Schema.default()

  defp t(text, marks \\ []),
    do: %{"type" => "text", "text" => text, "marks" => Enum.map(marks, &%{"type" => &1})}

  defp p(content), do: %{"type" => "paragraph", "content" => content}
  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp li(content), do: %{"type" => "list_item", "content" => content}

  defp md(content, schema \\ Schema.default(), opts \\ []) do
    {:ok, document} = Document.validate(doc(content), schema)
    Markdown.to_markdown(document, schema, opts)
  end

  describe "to_markdown/3" do
    test "writes the shipped blocks and marks" do
      assert md([
               %{"type" => "heading", "attrs" => %{"level" => 2}, "content" => [t("Notes")]},
               p([
                 t("Fixed "),
                 t("three", ["bold"]),
                 t(" bugs", ["bold"]),
                 t(" and "),
                 t("one", ["italic"])
               ]),
               p([t("gone", ["strike"]), t(" and "), t("code", ["code"])]),
               %{"type" => "horizontal_rule"}
             ]) == "## Notes\n\nFixed **three bugs** and *one*\n\n~~gone~~ and `code`\n\n---"
    end

    test "is nothing for nothing" do
      assert Markdown.to_markdown(nil) == ""
    end

    test "escapes what Markdown would read as syntax" do
      assert md([p([t("# not a heading")])]) == "\\# not a heading"
      assert md([p([t("1. not a list")])]) == "1\\. not a list"

      assert md([p([t("*a* _b_ `c` [d](e) <f> & | ~")])]) ==
               "\\*a\\* \\_b\\_ \\`c\\` \\[d\\](e) \\<f\\> \\& \\| \\~"
    end

    test "writes a span as HTML where its delimiters would not count" do
      assert md([p([t("a"), t("*b", ["bold"])])]) == "a<strong>\\*b</strong>"
      assert md([p([t("x"), t(" spaced ", ["italic"]), t("y")])]) == "x<em> spaced </em>y"
    end

    # Each of these was found by the round-trip properties, and each is
    # pinned here, where it does not depend on what a run happens to draw.
    test "comes back as it went, at the edges of what Markdown can say" do
      link = fn text ->
        %{
          "type" => "text",
          "text" => text,
          "marks" => [%{"type" => "link", "attrs" => %{"href" => "/a"}}]
        }
      end

      cases = [
        # `## C#` would lose its `#` to the closing sequence.
        {[%{"type" => "heading", "attrs" => %{"level" => 2}, "content" => [t("C#")]}], "## C\\#"},
        # `![` opens an image.
        {[p([t("look!"), link.("x")])], "look\\![x](</a>)"},
        # A line's leading spaces are dropped by Markdown, after a line break too.
        {[p([t("a"), %{"type" => "hard_break"}, t("  b")])], "a\\\n&#32;&#32;b"},
        # Two spans side by side would merge their delimiter runs.
        {[p([t("a", ["bold"]), t("b", ["italic"])])], "<strong>a</strong>*b*"}
      ]

      for {content, markdown} <- cases do
        {:ok, document} = Document.validate(doc(content), schema())
        assert Markdown.to_markdown(document, schema()) == markdown

        {:ok, via_html, _} = Coelho.from_html(Coelho.to_html(document), schema())
        assert {:ok, ^via_html, _} = Markdown.from_markdown(markdown, schema())
      end
    end

    # A mark of the application's own writes its delimiters as given, so a
    # span after it has to look at what it ended with.
    test "does not let a span's delimiters run into an override's" do
      schema = Schema.extend(Schema.default(), marks: [highlight: []])

      assert md([p([t("a", ["highlight"]), t("b", ["bold"])])], schema,
               marks: %{highlight: {"*", "*"}}
             ) ==
               "*a*<strong>b</strong>"
    end

    test "fences code with more backticks than it holds, and keeps its language" do
      code = %{
        "type" => "code_block",
        "attrs" => %{"language" => "elixir"},
        "content" => [t("IO.puts(\"```\")")]
      }

      assert md([code]) == "````elixir\nIO.puts(\"```\")\n````"
      assert md([p([t("a `b` c", ["code"])])]) == "``a `b` c``"
    end

    test "nests lists and quotes by indentation, and keeps an ordered list's start" do
      assert md([
               %{
                 "type" => "ordered_list",
                 "attrs" => %{"start" => 3},
                 "content" => [
                   li([
                     p([t("three")]),
                     %{"type" => "bullet_list", "content" => [li([p([t("nested")])])]}
                   ]),
                   li([p([t("four")])])
                 ]
               },
               %{"type" => "blockquote", "content" => [p([t("quoted")]), p([t("again")])]}
             ]) == "3. three\n   - nested\n4. four\n\n> quoted\n>\n> again"
    end

    # Two lists of one kind in a row are one list to Markdown.
    test "gives two lists in a row different markers" do
      list = fn type -> %{"type" => type, "content" => [li([p([t("x")])])]} end

      assert md([list.("bullet_list"), list.("bullet_list"), list.("bullet_list")]) ==
               "- x\n\n* x\n\n- x"

      assert md([list.("ordered_list"), list.("ordered_list")]) == "1. x\n\n1) x"
    end

    test "writes a table as a pipe table, its first row the header" do
      schema = Coelho.Schema.Default.build(tables: true)
      cell = fn type, text -> %{"type" => type, "content" => [p([t(text)])]} end

      table = %{
        "type" => "table",
        "content" => [
          %{
            "type" => "table_row",
            "content" => [cell.("table_header", "a | b"), cell.("table_header", "c")]
          },
          %{
            "type" => "table_row",
            "content" => [cell.("table_cell", "1"), cell.("table_cell", "2")]
          }
        ]
      }

      assert md([table], schema) == "| a \\| b | c |\n| --- | --- |\n| 1 | 2 |"
    end

    test "writes a heading holding a line break as Coelho's own HTML" do
      heading = %{
        "type" => "heading",
        "attrs" => %{"level" => 3},
        "content" => [t("a <b>"), %{"type" => "hard_break"}, t("c")]
      }

      assert md([heading]) == "<h3>a &lt;b&gt;<br>c</h3>"
    end

    test "links an attachment through the resolver, or names it" do
      attachment = %{
        "type" => "attachment",
        "attrs" => %{"key" => "k1", "filename" => "plan [v2].pdf", "caption" => "# Q3"}
      }

      assert md([attachment], Schema.default(), context: %{resolve: &("/files/" <> &1)}) ==
               "[plan \\[v2\\].pdf](</files/k1>)\n\n\\# Q3"

      assert md([attachment]) == "plan \\[v2\\].pdf\n\n\\# Q3"
    end

    test "takes the application's own nodes and marks" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [
            mention: [
              group: "inline",
              inline: true,
              void: true,
              attrs: [handle: [required: true]],
              to_text: &__MODULE__.handle/1
            ],
            callout: [group: "block", content: "inline*"]
          ],
          marks: [highlight: []]
        )

      content = [
        p([
          %{"type" => "mention", "attrs" => %{"handle" => "ada"}},
          t(" "),
          t("hi", ["highlight"])
        ]),
        %{"type" => "callout", "content" => [t("# careful")]}
      ]

      # Without an override: a void node's :to_text, escaped like any text.
      assert md(content, schema) == "\\_ada hi\n\n\\# careful"

      assert md(content, schema,
               nodes: %{mention: fn node, _children -> "@" <> node["attrs"]["handle"] end},
               marks: %{highlight: {"==", "=="}}
             ) == "@ada ==hi==\n\n\\# careful"
    end
  end

  def handle(node), do: "_" <> node["attrs"]["handle"]

  describe "from_markdown/3" do
    test "imports under the schema, which keeps what it allows and nothing else" do
      {:ok, document, warnings} =
        Markdown.from_markdown(
          "# Hi\n\n**bold** <script>alert(1)</script> [x](javascript:alert(1))"
        )

      assert Coelho.to_html(document) == "<h1>Hi</h1><p><strong>bold</strong> x</p>"
      assert Enum.any?(warnings, &(&1.tag == "script"))
    end

    test "keeps straight quotes, as they were typed" do
      {:ok, document, _warnings} = Markdown.from_markdown(~s(He said "it's fine"))

      assert Coelho.to_text(document) =~ ~s(He said "it's fine")
    end
  end

  # The oracle: Markdown has to say what HTML says. Both go back through
  # `Coelho.HTML.from_html/3`, so whitespace and what the schema keeps are
  # normalised the same way, and any difference is the Markdown's fault —
  # an escape missing, a delimiter that did not count.
  # What Markdown cannot say, taken out of the generated document before the
  # comparison — each is in the moduledoc's list. A paragraph with nothing
  # to show is not one Markdown can write, and a line break at the edge of a
  # paragraph is trailing whitespace to it.
  defp expressible(%{"type" => type} = node) when type in ["paragraph", "heading"] do
    content =
      node
      |> Map.get("content", [])
      |> Enum.drop_while(&edge?/1)
      |> Enum.reverse()
      |> Enum.drop_while(&edge?/1)
      |> Enum.reverse()

    Map.put(node, "content", Enum.map(content, &expressible/1))
  end

  defp expressible(%{"content" => content} = node) do
    kept =
      content
      |> Enum.map(&expressible/1)
      |> Enum.reject(&(&1["type"] in ["paragraph", "heading"] and blank?(&1)))

    Map.put(node, "content", kept)
  end

  # `![](src)` has an alt, and it is empty: Markdown cannot leave it out.
  defp expressible(%{"type" => "image"} = node),
    do: Map.update(node, "attrs", %{"alt" => ""}, &Map.put_new(&1, "alt", ""))

  defp expressible(node), do: node

  # CommonMark renders a destination percent-encoded where it has to — `[`,
  # `]`, a space — so a URL comes back as the same URL, written otherwise.
  # Compared decoded, on both sides.
  defp same_urls(%{} = node) do
    node
    |> Map.new(fn
      {"attrs", attrs} -> {"attrs", Map.new(attrs, &decode_url/1)}
      {"marks", marks} -> {"marks", Enum.map(marks, &same_urls/1)}
      {"content", content} -> {"content", Enum.map(content, &same_urls/1)}
      other -> other
    end)
  end

  defp decode_url({key, url}) when key in ["href", "src"] and is_binary(url),
    do: {key, URI.decode(url)}

  defp decode_url(pair), do: pair

  defp edge?(%{"type" => "hard_break"}), do: true
  defp edge?(%{"type" => "text", "text" => text}), do: String.trim(text) == ""
  defp edge?(_node), do: false

  defp blank?(paragraph) do
    Enum.all?(Map.get(paragraph, "content", []), fn
      %{"type" => "text", "text" => text} -> String.trim(text) == ""
      %{"type" => "hard_break"} -> true
      _other -> false
    end)
  end

  property "a document comes back from Markdown as it comes back from HTML" do
    check all(
            generated <- document([:attachment]),
            validated = Document.validate(expressible(generated), schema()),
            match?({:ok, _}, validated),
            max_runs: 300
          ) do
      {:ok, document} = validated

      markdown = Markdown.to_markdown(document, schema())
      {:ok, via_html, _warnings} = Coelho.from_html(Coelho.to_html(document, schema()), schema())
      {:ok, via_markdown, _warnings} = Markdown.from_markdown(markdown, schema())

      assert same_urls(via_markdown) == same_urls(via_html), """
      Markdown:
      #{markdown}
      """
    end
  end

  # The shared generator draws printable Unicode, which rarely lands on what
  # Markdown reads as syntax. This one draws mostly that: delimiters at the
  # edges of marks, line-start markers after line breaks, backslashes,
  # backticks inside code, lists of both kinds side by side.
  @hostile [
    "*",
    "**",
    "_",
    "__",
    "`",
    "``",
    "```",
    "~",
    "~~",
    "#",
    "##",
    "-",
    "--",
    "---",
    "+",
    "=",
    "==",
    ">",
    "|",
    "[",
    "]",
    "(",
    ")",
    "!",
    "&",
    "\\",
    "<",
    "1.",
    "1)",
    "2.",
    "a",
    "b",
    "word",
    ".",
    ",",
    ":",
    " ",
    "  ",
    "x y"
  ]

  defp hostile_text,
    do: list_of(member_of(@hostile), min_length: 1, max_length: 6) |> map(&Enum.join/1)

  defp hostile_marks do
    list_of(
      member_of([
        %{"type" => "bold"},
        %{"type" => "italic"},
        %{"type" => "strike"},
        %{"type" => "code"},
        %{"type" => "link", "attrs" => %{"href" => "/a(b)?c=*d*"}}
      ]),
      max_length: 3
    )
    |> map(&Enum.uniq/1)
  end

  defp hostile_inline do
    one_of([
      gen all(text <- hostile_text(), marks <- hostile_marks()) do
        %{"type" => "text", "text" => text, "marks" => marks}
      end,
      constant(%{"type" => "hard_break"}),
      gen all(alt <- hostile_text()) do
        %{"type" => "image", "attrs" => %{"src" => "/i*_[x].png", "alt" => alt}}
      end
    ])
  end

  defp hostile_paragraph do
    gen all(content <- list_of(hostile_inline(), min_length: 1, max_length: 6)) do
      %{"type" => "paragraph", "content" => content}
    end
  end

  defp hostile_block do
    one_of([
      hostile_paragraph(),
      gen all(
            level <- integer(1..6),
            content <- list_of(hostile_inline(), min_length: 1, max_length: 4)
          ) do
        %{"type" => "heading", "attrs" => %{"level" => level}, "content" => content}
      end,
      gen all(
            items <- list_of(hostile_paragraph(), min_length: 1, max_length: 3),
            type <- member_of(~w(bullet_list ordered_list))
          ) do
        %{
          "type" => type,
          "content" => Enum.map(items, &%{"type" => "list_item", "content" => [&1]})
        }
      end,
      gen all(content <- list_of(hostile_paragraph(), min_length: 1, max_length: 2)) do
        %{"type" => "blockquote", "content" => content}
      end,
      gen all(text <- hostile_text()) do
        %{"type" => "code_block", "content" => [%{"type" => "text", "text" => text}]}
      end,
      constant(%{"type" => "horizontal_rule"})
    ])
  end

  property "what Markdown reads as syntax comes back as the characters that were typed" do
    check all(
            blocks <- list_of(hostile_block(), min_length: 1, max_length: 5),
            validated =
              Document.validate(expressible(%{"type" => "doc", "content" => blocks}), schema()),
            match?({:ok, _}, validated),
            max_runs: 500
          ) do
      {:ok, document} = validated

      markdown = Markdown.to_markdown(document, schema())
      {:ok, via_html, _warnings} = Coelho.from_html(Coelho.to_html(document, schema()), schema())
      {:ok, via_markdown, _warnings} = Markdown.from_markdown(markdown, schema())

      assert same_urls(via_markdown) == same_urls(via_html), """
      Markdown:
      #{markdown}
      """
    end
  end
end
