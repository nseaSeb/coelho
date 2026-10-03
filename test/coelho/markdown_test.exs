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

    # Found by review, then by the properties once their generators could
    # draw it; each comes back as the HTML round trip would bring it.
    test "comes back as it went, in tables, lists and around empty blocks" do
      schema = Coelho.Schema.Default.build(tables: true)
      list = fn type, items -> %{"type" => type, "content" => Enum.map(items, &li/1)} end
      cell = fn type, content -> %{"type" => type, "content" => [p(content)]} end
      code = fn text -> t(text, ["code"]) end

      table = fn cells ->
        %{
          "type" => "table",
          "content" => [
            %{"type" => "table_row", "content" => [cell.("table_header", [t("h")])]},
            %{"type" => "table_row", "content" => [cell.("table_cell", cells)]}
          ]
        }
      end

      href = %{
        "type" => "text",
        "text" => "l",
        "marks" => [%{"type" => "link", "attrs" => %{"href" => "/a|b"}}]
      }

      cases = [
        # An empty paragraph between two lists does not keep them apart.
        {[list.("bullet_list", [[p([t("a")])]]), p([]), list.("bullet_list", [[p([t("b")])]])],
         "- a\n\n* b"},
        # An ordered list starting at 3 cannot follow a paragraph on the next line.
        {[
           list.("bullet_list", [
             [
               p([t("a")]),
               %{
                 "type" => "ordered_list",
                 "attrs" => %{"start" => 3},
                 "content" => [li([p([t("b")])])]
               }
             ]
           ])
         ], "- a\n\n  3. b"},
        # A `|` in a cell's code, its link, or with a backslash before it.
        {[table.([code.("a|b")])], "| h |\n| --- |\n| <code>a&#124;b</code> |"},
        {[table.([code.("\\|")])], "| h |\n| --- |\n| <code>&#92;&#124;</code> |"},
        {[table.([href])], "| h |\n| --- |\n| [l](</a%7Cb>) |"},
        {[
           table.([
             %{
               "type" => "text",
               "text" => "l",
               "marks" => [%{"type" => "link", "attrs" => %{"href" => "/a", "title" => "t|u"}}]
             }
           ])
         ], "| h |\n| --- |\n| [l](</a> \"t&#124;u\") |"},
        {[table.([t("x\\|y")])], "| h |\n| --- |\n| x\\\\&#124;y |"},
        # A line break in a cell, which is one line.
        {[table.([t("x"), %{"type" => "hard_break"}, t("y")])], "| h |\n| --- |\n| x<br>y |"},
        # A typed backslash before a `!` that a link follows.
        {[p([t("x\\!"), href])], "x\\\\\\![l](</a|b>)"},
        # A line break at the edge of a paragraph or heading is not written.
        {[p([%{"type" => "hard_break"}, t("x"), %{"type" => "hard_break"}])], "x"},
        {[
           %{
             "type" => "heading",
             "attrs" => %{"level" => 1},
             "content" => [t("x"), %{"type" => "hard_break"}]
           }
         ], "# x"}
      ]

      for {content, markdown} <- cases do
        {:ok, document} = Document.validate(doc(content), schema)
        assert Markdown.to_markdown(document, schema) == markdown

        {:ok, via_html, _} =
          Coelho.from_html(Coelho.to_html(expressible(document), schema), schema)

        {:ok, via_markdown, _} = Markdown.from_markdown(markdown, schema)
        assert same_urls(via_markdown) == same_urls(via_html), markdown
      end
    end

    # The second review's cases, each coming back as the HTML round trip.
    test "comes back as it went, with empty items, cells holding blocks, and long numbers" do
      schema = Coelho.Schema.Default.build(tables: true)
      empty = p([])
      ul = fn items -> %{"type" => "bullet_list", "content" => Enum.map(items, &li/1)} end

      ol = fn start, items ->
        %{
          "type" => "ordered_list",
          "attrs" => %{"start" => start},
          "content" => Enum.map(items, &li/1)
        }
      end

      header = fn content ->
        %{
          "type" => "table",
          "content" => [
            %{
              "type" => "table_row",
              "content" => [%{"type" => "table_header", "content" => content}]
            }
          ]
        }
      end

      code = %{
        "type" => "code_block",
        "attrs" => %{"language" => "elixir"},
        "content" => [t("x |\\| y\nz")]
      }

      cases = [
        {[ul.([[p([t("a")])], [empty]])], "- a\n- "},
        {[ul.([[p([t("a")]), ul.([[empty]])]])], "- a\n\n  - "},
        {[ul.([[p([t("a")]), ol.(1, [[empty]])]])], "- a\n\n  1. "},
        {[%{"type" => "heading", "attrs" => %{"level" => 1}, "content" => [t("a #  ")]}],
         "# a \\#  "},
        {[ol.(999_999_999, [[p([t("a")])], [p([t("b")])]])],
         ~s(<ol start="999999999"><li><p>a</p></li><li><p>b</p></li></ol>)},
        {[header.([p([t("a\\")]), ul.([[p([t("b")])]])])],
         "| <p>a&#92;</p><ul><li><p>b</p></li></ul> |\n| --- |"},
        {[header.([code])],
         ~s(| <pre><code class="language-elixir">x &#124;&#92;&#124; y&#10;z</code></pre> |\n| --- |)},
        {[
           p([
             %{
               "type" => "text",
               "text" => "]:",
               "marks" => [%{"type" => "link", "attrs" => %{"href" => "/a"}}, %{"type" => "code"}]
             }
           ])
         ], "[<code>&#93;&#58;</code>](</a>)"}
      ]

      for {content, markdown} <- cases do
        {:ok, document} = Document.validate(doc(content), schema)
        assert Markdown.to_markdown(document, schema) == markdown

        {:ok, via_html, _} =
          Coelho.from_html(Coelho.to_html(expressible(document), schema), schema)

        {:ok, via_markdown, _} = Markdown.from_markdown(markdown, schema)
        assert same_urls(via_markdown) == same_urls(via_html), markdown
      end
    end

    # The third review's cases. comrak decodes an entity in a destination or
    # a title even after `\&`, so the `&` is written as `&#38;`.
    test "comes back as it went, with a rule opening an item and entities in links" do
      link = %{
        "type" => "text",
        "text" => "x",
        "marks" => [
          %{"type" => "link", "attrs" => %{"href" => "/?a=1&copy;b", "title" => "&amp; me"}}
        ]
      }

      image = %{
        "type" => "image",
        "attrs" => %{"src" => "/i&lt;", "alt" => "a", "title" => "&lt;"}
      }

      cases = [
        {[%{"type" => "bullet_list", "content" => [li([p([]), %{"type" => "horizontal_rule"}])]}],
         "-\n  ---"},
        # Three empty items nested: `- - - ` is a thematic break.
        {[
           %{
             "type" => "bullet_list",
             "content" => [
               li([
                 p([]),
                 %{
                   "type" => "bullet_list",
                   "content" => [
                     li([p([]), %{"type" => "bullet_list", "content" => [li([p([])])]}])
                   ]
                 }
               ])
             ]
           }
         ], "-\n  -\n    - "},
        {[p([link])], ~s|[x](</?a=1&#38;copy;b> "&#38;amp; me")|},
        {[p([image])], ~s|![a](</i&#38;lt;> "&#38;lt;")|}
      ]

      for {content, markdown} <- cases do
        {:ok, document} = Document.validate(doc(content), schema())
        assert Markdown.to_markdown(document, schema()) == markdown

        {:ok, via_html, _} = Coelho.from_html(Coelho.to_html(expressible(document)), schema())
        {:ok, via_markdown, _} = Markdown.from_markdown(markdown, schema())
        assert same_urls(via_markdown) == same_urls(via_html), markdown
      end
    end

    test "keeps an attachment's leading spaces from making it code" do
      attachment = %{"type" => "attachment", "attrs" => %{"key" => "k", "filename" => "    plan"}}
      assert md([attachment]) == "&#32;&#32;&#32;&#32;plan"
    end

    test "keeps an attachment's name a name when it looks like a block" do
      for name <- ["1. report.pdf", "- notes", "# draft"] do
        attachment = %{"type" => "attachment", "attrs" => %{"key" => "k", "filename" => name}}
        {:ok, back, _} = Markdown.from_markdown(md([attachment]))

        assert [%{"type" => "paragraph"}] = back["content"]
        assert Coelho.to_text(back) =~ name
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

      # A typed `|` in a cell is its entity: see "pipes in a table" below.
      assert md([table], schema) == "| a &#124; b | c |\n| --- | --- |\n| 1 | 2 |"
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

  # An empty paragraph a container needs — a list item's first, the first of
  # a cell or a quote that holds nothing else — stays: the import puts it
  # back, as the editor does.
  defp expressible(%{"content" => content} = node) do
    kept =
      content
      |> Enum.map(&expressible/1)
      |> Enum.with_index()
      |> Enum.reject(fn {child, index} ->
        child["type"] in ["paragraph", "heading"] and blank?(child) and
          not required?(node, child, index, content)
      end)
      |> Enum.map(&elem(&1, 0))

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

  defp required?(%{"type" => "list_item"}, %{"type" => "paragraph"}, 0, _content), do: true

  defp required?(%{"type" => type}, %{"type" => "paragraph"}, 0, content)
       when type in ["table_cell", "table_header", "blockquote"],
       do: Enum.all?(content, &(&1["type"] == "paragraph" and blank?(&1)))

  defp required?(_node, _child, _index, _content), do: false

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
    "\\!",
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
        %{"type" => "link", "attrs" => %{"href" => "/a(b)?c=*d*"}},
        %{"type" => "link", "attrs" => %{"href" => "/a|b"}},
        %{
          "type" => "link",
          "attrs" => %{"href" => "/?a=1&copy;b&amp;c", "title" => "&amp;amp; me"}
        }
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
        %{
          "type" => "image",
          "attrs" => %{"src" => "/i*_[x].png&lt;", "alt" => alt, "title" => alt <> "&lt;"}
        }
      end
    ])
  end

  defp hostile_paragraph do
    gen all(content <- list_of(hostile_inline(), min_length: 1, max_length: 6)) do
      %{"type" => "paragraph", "content" => content}
    end
  end

  # Now and then empty: an item, a cell, a nested list's first item.
  defp maybe_empty_paragraph do
    frequency([
      {4, hostile_paragraph()},
      {1, constant(%{"type" => "paragraph", "content" => []})}
    ])
  end

  defp hostile_list(depth) do
    gen all(
          type <- member_of(~w(bullet_list ordered_list)),
          start <- one_of([integer(0..4), constant(999_999_999)]),
          items <- list_of(hostile_item(depth), min_length: 1, max_length: 3)
        ) do
      list = %{"type" => type, "content" => items}
      if type == "ordered_list", do: Map.put(list, "attrs", %{"start" => start}), else: list
    end
  end

  # A paragraph, and at the first level possibly a list nested under it.
  defp hostile_item(0) do
    gen all(paragraph <- maybe_empty_paragraph()) do
      %{"type" => "list_item", "content" => [paragraph]}
    end
  end

  defp hostile_item(depth) do
    gen all(
          paragraph <- maybe_empty_paragraph(),
          nested <-
            one_of([
              constant(nil),
              hostile_list(depth - 1),
              constant(%{"type" => "horizontal_rule"}),
              map(
                hostile_text(),
                &%{"type" => "code_block", "content" => [%{"type" => "text", "text" => &1}]}
              )
            ])
        ) do
      %{"type" => "list_item", "content" => Enum.reject([paragraph, nested], &is_nil/1)}
    end
  end

  # One row of headers, then cells: a pipe table's first row is its header.
  defp hostile_table do
    gen all(
          width <- integer(1..3),
          rows <-
            list_of(list_of(hostile_cell(), length: width), min_length: 1, max_length: 3)
        ) do
      row = fn cells, type ->
        %{
          "type" => "table_row",
          "content" => Enum.map(cells, &%{"type" => type, "content" => &1})
        }
      end

      [header | body] = rows

      %{
        "type" => "table",
        "content" => [row.(header, "table_header") | Enum.map(body, &row.(&1, "table_cell"))]
      }
    end
  end

  # What a cell holds: usually one paragraph, sometimes what a pipe table
  # cannot write as Markdown.
  defp hostile_cell do
    frequency([
      {4, map(maybe_empty_paragraph(), &[&1])},
      {1, list_of(hostile_paragraph(), length: 2)},
      {1,
       gen all(text <- hostile_text()) do
         [
           %{
             "type" => "code_block",
             "attrs" => %{"language" => "elixir"},
             "content" => [%{"type" => "text", "text" => text <> "\n" <> text}]
           }
         ]
       end},
      {1, map(hostile_list(0), &[&1])}
    ])
  end

  defp hostile_block do
    one_of([
      hostile_paragraph(),
      # Written as nothing, between blocks that must stay apart.
      constant(%{"type" => "paragraph", "content" => []}),
      gen all(
            level <- integer(1..6),
            content <- list_of(hostile_inline(), min_length: 1, max_length: 4)
          ) do
        %{"type" => "heading", "attrs" => %{"level" => level}, "content" => content}
      end,
      hostile_list(2),
      gen all(content <- list_of(hostile_paragraph(), min_length: 1, max_length: 2)) do
        %{"type" => "blockquote", "content" => content}
      end,
      gen all(text <- hostile_text()) do
        %{"type" => "code_block", "content" => [%{"type" => "text", "text" => text}]}
      end,
      constant(%{"type" => "horizontal_rule"}),
      hostile_table()
    ])
  end

  defp tables, do: Coelho.Schema.Default.build(tables: true)

  # The document as generated is what is written, empty blocks and all; what
  # it is compared with is the HTML round trip of what Markdown can say of it.
  property "what Markdown reads as syntax comes back as the characters that were typed" do
    check all(
            blocks <- list_of(hostile_block(), min_length: 1, max_length: 5),
            generated = %{"type" => "doc", "content" => blocks},
            original = Document.validate(generated, tables()),
            expressed = Document.validate(expressible(generated), tables()),
            match?({:ok, _}, original) and match?({:ok, _}, expressed),
            max_runs: 500
          ) do
      {:ok, document} = original
      {:ok, expressed} = expressed

      markdown = Markdown.to_markdown(document, tables())
      {:ok, via_html, _warnings} = Coelho.from_html(Coelho.to_html(expressed, tables()), tables())
      {:ok, via_markdown, _warnings} = Markdown.from_markdown(markdown, tables())

      assert same_urls(via_markdown) == same_urls(via_html), """
      Markdown:
      #{markdown}
      """
    end
  end

  # Without a URL an attachment is its name, a paragraph like any other: a
  # name that looks like a list or a heading has to stay a name.
  property "an attachment's name and caption come back as the words they were" do
    check all(name <- hostile_text(), caption <- one_of([constant(nil), hostile_text()])) do
      attrs = %{"key" => "k", "filename" => name}
      attrs = if caption, do: Map.put(attrs, "caption", caption), else: attrs

      {:ok, document} =
        Document.validate(doc([%{"type" => "attachment", "attrs" => attrs}]), schema())

      {:ok, back, _warnings} = Markdown.from_markdown(Markdown.to_markdown(document), schema())

      words = fn text -> text |> String.split() |> Enum.join(" ") end
      expected = Enum.reject([name, caption], &(is_nil(&1) or words.(&1) == ""))

      # A document with nothing in it reads back as one empty paragraph.
      back_words =
        back["content"]
        |> Enum.map(&words.(Coelho.to_text(doc([&1]))))
        |> Enum.reject(&(&1 == ""))

      assert back_words == Enum.map(expected, words)
    end
  end
end
