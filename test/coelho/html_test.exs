defmodule Coelho.HTMLTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, HTML, Schema}

  defp import_html!(html, schema \\ Schema.default()) do
    {:ok, document, _warnings} = HTML.from_html(html, schema)
    document
  end

  defp round_trip(html), do: html |> import_html!() |> Coelho.to_html()

  describe "how long the import takes" do
    @tag timeout: 20_000
    test "grows with the size of the fragment, not with its square" do
      # The `<pre>` pre-pass was a lazy regex, and `.*?` starts its search
      # again at every `<pre`, running to the end of the input when nothing
      # closes it: 20 KB of unclosed `<pre>` took 346 ms, and a paste out of
      # a word processor is a great deal more than 20 KB.
      #
      # A ratio rather than a duration: four times the input costs about four
      # times the time when the work is linear, sixteen when it is the
      # square, so the line sits halfway between.
      # Big enough that the baseline is tens of milliseconds: at half a
      # millisecond it was scheduler noise, and this failed once in four runs
      # under `max_cases: 16` while passing every time in isolation — a test
      # that cries wolf about the very thing it exists to watch.
      small = import_time(40_000)
      large = import_time(160_000)

      ratio = large / max(small, 1)

      assert ratio < 8,
             "4x the fragment cost #{Float.round(ratio, 1)}x the time " <>
               "(#{small}µs then #{large}µs), which is the square creeping back"
    end

    # The best of three, for the same reason: what is being measured is the
    # shape of the work, and the fastest run is the one least polluted by
    # everything else the machine was doing.
    defp import_time(bytes) do
      html = String.duplicate("<pre>", div(bytes, 5))

      1..3
      |> Enum.map(fn _ ->
        {micro, {:ok, _document, []}} =
          :timer.tc(fn -> Coelho.HTML.from_html(html, Schema.default(), warnings: false) end)

        micro
      end)
      |> Enum.min()
    end
  end

  describe "blocks and marks" do
    test "maps the tags the schema declares" do
      assert round_trip("<p>Hello <strong>bold</strong> and <em>italic</em>.</p>") ==
               "<p>Hello <strong>bold</strong> and <em>italic</em>.</p>"
    end

    test "accepts the aliases people actually write" do
      assert round_trip("<p><b>b</b><i>i</i><del>d</del></p>") ==
               "<p><strong>b</strong><em>i</em><s>d</s></p>"
    end

    test "maps every heading level" do
      for level <- 1..6 do
        assert round_trip("<h#{level}>T</h#{level}>") == "<h#{level}>T</h#{level}>"
      end
    end

    test "keeps list structure, and nesting" do
      html = "<ul><li>one<ul><li>deep</li></ul></li></ul>"

      assert round_trip(html) ==
               "<ul><li><p>one</p><ul><li><p>deep</p></li></ul></li></ul>"
    end

    test "reads an ordered list start" do
      assert round_trip(~s(<ol start="3"><li>a</li></ol>)) ==
               ~s(<ol start="3"><li><p>a</p></li></ol>)
    end

    test "keeps line breaks and rules" do
      assert round_trip("<p>a<br>b</p><hr>") == "<p>a<br>b</p><hr>"
    end

    test "decodes entities" do
      assert round_trip("<p>a &amp; b &lt;c&gt;</p>") == "<p>a &amp; b &lt;c&gt;</p>"
    end
  end

  describe "markup the schema does not know" do
    test "an unknown element is transparent, its children survive" do
      assert round_trip(~s(<div><section><p>kept</p></section></div>)) == "<p>kept</p>"
      assert round_trip(~s(<p>a <span class="fancy">b</span></p>)) == "<p>a b</p>"
    end

    test "script and style are dropped with their content" do
      html = "<p>before</p><script>alert(1)</script><style>p{}</style><p>after</p>"

      assert round_trip(html) == "<p>before</p><p>after</p>"
    end

    test "an element whose attributes fail validation is treated as unknown" do
      # The link text is content the reader saw; the link is not.
      assert round_trip(~s|<p><a href="javascript:alert(1)">text</a></p>|) == "<p>text</p>"
      assert round_trip(~s(<p><img alt="no src"></p>)) == "<p></p>"
    end

    test "an optional attribute failing validation falls back to its default" do
      assert round_trip(~s(<ol start="not a number"><li>a</li></ol>)) ==
               "<ol><li><p>a</p></li></ol>"
    end

    test "a valid image survives with its attributes" do
      assert round_trip(~s(<p><img src="/a.png" alt="A" title="T"></p>)) ==
               ~s(<p><img src="/a.png" alt="A" title="T"></p>)
    end
  end

  describe "content that does not fit where it lands" do
    test "bare inline content at the top level becomes a paragraph" do
      assert round_trip("Hello") == "<p>Hello</p>"
      assert round_trip("<strong>Hello</strong>") == "<p><strong>Hello</strong></p>"
    end

    test "a list item holding bare text gets its paragraph" do
      assert round_trip("<ul><li>text</li></ul>") == "<ul><li><p>text</p></li></ul>"
    end

    test "a blockquote holding bare text gets its paragraph" do
      assert round_trip("<blockquote>quoted</blockquote>") ==
               "<blockquote><p>quoted</p></blockquote>"
    end

    test "empty input still yields a valid document" do
      document = import_html!("")

      assert {:ok, ^document} = Document.validate(document, Schema.default())
      assert document["content"] != []
    end

    test "whitespace between blocks does not become paragraphs" do
      assert round_trip("<p>a</p>\n\n   \n<p>b</p>") == "<p>a</p><p>b</p>"
    end
  end

  describe "whitespace" do
    test "is collapsed the way HTML collapses it" do
      assert round_trip("<p>a\n   b\tc</p>") == "<p>a b c</p>"
    end

    test "is preserved inside a code block, tags and all" do
      html = "<pre><code>def a do\n  :ok\nend</code></pre>"

      assert round_trip(html) == "<pre><code>def a do\n  :ok\nend</code></pre>"
    end

    test "a space between inline elements is not lost" do
      assert round_trip("<p><strong>a</strong> <em>b</em></p>") ==
               "<p><strong>a</strong> <em>b</em></p>"
    end

    test "but a block does not begin or end with the source's indentation" do
      assert round_trip("<p>\n  spaced out\n</p>") == "<p>spaced out</p>"
    end

    test "and does not end with one hiding behind another" do
      # Trimming empties the last child and drops it, and what it was hiding
      # is then the last child in its turn. Stopping after one pass left a
      # document that trimmed further the next time it was imported.
      assert round_trip("<p>text<code> </code>   </p>") == "<p>text</p>"
      assert round_trip("<p>text<code> </code>b</p>") == "<p>text<code> </code>b</p>"
    end
  end

  describe "the result is a real document" do
    test "it is validated and normalised" do
      document = import_html!("<h3>T</h3>")

      assert {:ok, ^document} = Document.validate(document, Schema.default())
      assert [%{"attrs" => %{"level" => 3}}] = document["content"]
    end

    test "no HTML survives anywhere in it" do
      document = import_html!(~s(<p onclick="x" style="color:red">text</p>))

      refute inspect(document) =~ "onclick"
      refute inspect(document) =~ "color:red"
    end

    test "text is stored decoded, not escaped" do
      document = import_html!("<p>a &amp; b</p>")

      assert [%{"content" => [%{"text" => "a & b"}]}] = document["content"]
    end
  end

  describe "a schema of your own" do
    test "imports through the rules it declares" do
      schema =
        Schema.new(
          nodes: [
            doc: [content: "line+"],
            line: [content: "inline*", group: "block", render: {"p", []}, parse: ~w(p div)]
          ],
          marks: [highlight: [render: {"mark", []}, parse: ["mark"]]]
        )

      document = import_html!("<div>a <mark>b</mark></div><p>c</p>", schema)

      assert Coelho.to_html(document, schema) == "<p>a <mark>b</mark></p><p>c</p>"
    end

    test "reports what still does not fit rather than guessing" do
      # A top node that admits only images has nowhere to put text, and no
      # block to wrap it in.
      schema =
        Schema.new(
          nodes: [
            doc: [content: "image+"],
            image: [
              group: "inline",
              inline: true,
              void: true,
              attrs: [src: [required: true, validate: :safe_url]],
              parse: [{"img", &Coelho.HTML.take(&1, ["src"])}]
            ]
          ]
        )

      assert {:error, [_ | _]} = HTML.from_html("<p>text</p>", schema)
    end
  end

  describe "whitespace the parser would have eaten" do
    test "a separator between two inline elements survives" do
      # Floki's default parser drops data nodes made only of whitespace, so
      # this pair would otherwise import as "ab".
      assert round_trip("<p><b>a</b> <i>b</i></p>") == "<p><strong>a</strong> <em>b</em></p>"
      assert round_trip("<p><b>a</b>\n<i>b</i></p>") == "<p><strong>a</strong> <em>b</em></p>"
    end

    test "the same whitespace between two blocks is still dropped" do
      assert round_trip("<p>a</p>   <p>b</p>") == "<p>a</p><p>b</p>"
    end

    test "the carrier character never reaches the document" do
      document = import_html!("<p><b>a</b> <i>b</i></p>")

      refute inspect(document) =~ "e000"
      refute document |> Coelho.to_text() |> String.contains?("\u{E000}")
    end

    test "a carrier character present in the source is stripped, not honoured" do
      assert round_trip("<p>a\u{E000}b</p>") == "<p>ab</p>"
    end

    test "code block whitespace is left to the parser untouched" do
      assert round_trip("<pre><code>a\n\n  b</code></pre>") == "<pre><code>a\n\n  b</code></pre>"
    end

    test "a run split by an element the schema drops is collapsed as one run" do
      # The `<a>` has no href, so the link rule refuses it and the element
      # becomes transparent. Its text joins the text around it, and each half
      # had already kept one space of its own — storing both stores two, and
      # importing what that renders to collapses them, so a document would
      # lose a space on every round trip through storage.
      assert import_html!("<p>a   <a>   b</a></p>") ==
               %{
                 "type" => "doc",
                 "content" => [
                   %{
                     "type" => "paragraph",
                     "content" => [%{"type" => "text", "text" => "a b"}]
                   }
                 ]
               }
    end

    test "but a run is not joined across a mark, which owns its own space" do
      # The space inside the emphasis is emphasised. Collapsing the pair would
      # move it out, and what renders would no longer be what was written.
      assert round_trip("<p>a   <em>   b</em></p>") == "<p>a <em> b</em></p>"
    end

    test "a code block's whitespace is collapsed when its text is lifted out" do
      # A `<pre>` keeps its whitespace to the character, which is what a code
      # block is for. But `<p><pre>…</pre></p>` is not a code block anywhere
      # the schema allows one, so the block is lifted and its text lands in a
      # paragraph — verbatim, in a place where nothing keeps it. Stored like
      # that, the next import collapses it, and the round trip shortens the
      # text.
      assert import_html!("<p><p><pre>a   b</pre></p></p>") ==
               %{
                 "type" => "doc",
                 "content" => [
                   %{
                     "type" => "paragraph",
                     "content" => [%{"type" => "text", "text" => "a b"}]
                   }
                 ]
               }
    end

    test "and when the lifted text has to be wrapped in a block of its own" do
      # The same defect by a third route. `fit/3` lifts a code block that
      # cannot sit where it landed, and `wrap_inline_runs/3` then puts the
      # loose text into a default block — a path that built the block
      # directly, so the verbatim run reached storage uncollapsed. Needs a
      # schema with a parent that admits blocks but not code blocks, which
      # the shipped one has not.
      schema =
        Schema.new(
          top_node: :doc,
          nodes: [
            doc: [content: "block+"],
            quote: [
              content: "paragraph+",
              group: "block",
              render: {"blockquote", []},
              parse: ["blockquote"]
            ],
            paragraph: [content: "inline*", group: "block", render: {"p", []}, parse: ["p"]],
            code_block: [
              content: "text*",
              group: "block",
              marks: :none,
              render: &Coelho.Schema.Default.render_code_block/2,
              parse: ["pre"]
            ],
            text: [group: "inline", inline: true, text: true]
          ],
          marks: []
        )

      document = import_html!("<blockquote><pre>a   b</pre></blockquote>", schema)

      assert Document.to_text(document, schema) == "a b"
      assert import_html!(Coelho.to_html(document, schema), schema) == document
    end

    test "importing what was rendered gives the same document back" do
      for html <- [
            "<p>a   <a>   b</a></p>",
            "<p>a   <em>   b</em></p>",
            "<p>a <strong>b</strong> c</p>",
            "<div>a   <span>   b</span>   c</div>",
            "<p><p><pre>a   b</pre></p></p>",
            "<pre>a   b</pre>"
          ] do
        document = import_html!(html)

        assert import_html!(Coelho.to_html(document)) == document
      end
    end
  end

  describe "content that must not be lost" do
    test "an image outside a paragraph survives" do
      # Reading a "text" key off any node made an image look like whitespace,
      # and dropped the run it was in.
      assert round_trip(~s(<img src="/x.png">)) == ~s(<p><img src="/x.png"></p>)
      assert round_trip(~s(<div><img src="/x.png"></div>)) == ~s(<p><img src="/x.png"></p>)
      assert round_trip("<div><br></div>") == "<p><br></p>"
    end

    test "a block the parent cannot hold is unwrapped, not deleted" do
      # Floki does not auto-close <p> before <pre> the way a browser does, so
      # this arrives as a code block nested in a paragraph.
      assert round_trip("<p>a<pre>code</pre></p>") =~ "code"
      assert round_trip("<h1><h2>x</h2></h1>") == "<h1>x</h1>"
      assert round_trip("<li>text</li>") == "<p>text</p>"
    end

    test "a wrapped run does not keep the source's indentation" do
      assert round_trip("  Hello  ") == "<p>Hello</p>"

      assert round_trip("<blockquote>\n  quoted\n</blockquote>") ==
               "<blockquote><p>quoted</p></blockquote>"

      assert round_trip("<ul><li>\n  text\n</li></ul>") == "<ul><li><p>text</p></li></ul>"
    end

    test "a mark nested in itself is applied once" do
      assert round_trip("<p>a<b>b<b>c</b></b></p>") == "<p>a<strong>bc</strong></p>"
      assert round_trip("<p><strong>a <b>b</b></strong></p>") == "<p><strong>a b</strong></p>"
    end

    test "the carrier character never reaches an attribute either" do
      document = import_html!(~s(<p><a href="/x" title="a >  < b">link</a></p>))

      refute inspect(document) =~ "e000"

      assert [%{"content" => [%{"marks" => [%{"attrs" => %{"title" => title}}]}]}] =
               document["content"]

      refute String.contains?(title, "\u{E000}")
    end
  end

  describe "a rule that reads the element's text" do
    defmodule Mentions do
      @moduledoc false
      def schema do
        Coelho.Schema.extend(Coelho.Schema.default(),
          nodes: [
            mention: [
              group: "inline",
              inline: true,
              void: true,
              attrs: [
                user_id: [required: true, validate: :integer],
                label: [default: nil, validate: {:nullable, :string}]
              ],
              render: {"span", [{"class", "mention"}]},
              parse: [{"span", &__MODULE__.parse/2}]
            ]
          ]
        )
      end

      def parse(attrs, text) do
        case attrs |> Map.get("data-user-id", "") |> Integer.parse() do
          {user_id, ""} -> %{"user_id" => user_id, "label" => text}
          _ -> %{}
        end
      end
    end

    test "keeps what the element said" do
      document = import_html!(~s(<p><span data-user-id="7">Ada</span></p>), Mentions.schema())

      assert [%{"content" => [mention]}] = document["content"]
      assert mention["attrs"] == %{"user_id" => 7, "label" => "Ada"}
    end

    test "and still declines the spans that are not mentions" do
      document =
        import_html!(~s(<p><span class="fancy">plain</span></p>), Mentions.schema())

      assert [%{"content" => [%{"type" => "text", "text" => "plain"}]}] = document["content"]
    end

    test "an unparsable id is not a mention either" do
      document =
        import_html!(~s(<p><span data-user-id="abc">text</span></p>), Mentions.schema())

      assert [%{"content" => [%{"type" => "text"}]}] = document["content"]
    end
  end

  describe "what a code block quotes" do
    test "does not include a script or style that was inside it" do
      # `<script>` and `<style>` are dropped with their content everywhere
      # else, and a raw-text element survives the parser's whitespace
      # handling, so Floki's own text function let exactly that content
      # through here and nowhere else.
      assert round_trip("<pre>keep<style>  .a{}  </style><script>alert(1)</script></pre>") ==
               "<pre><code>keep</code></pre>"
    end

    test "keeps whitespace that is the whole of it" do
      # A code block that is only whitespace is still a code block. The parser
      # drops a whitespace-only node, and a closed `<pre>` is skipped by the
      # pass that protects those, so it came back empty — and a document
      # imported, rendered and imported again was not the same document.
      assert round_trip("<pre><code>   </code></pre>") == "<pre><code>   </code></pre>"
    end

    test "keeps indentation to the character" do
      # Fencing the run rather than replacing it: replacing would flatten
      # every indent to one space.
      source = "<pre><code>def a do\n    :ok\nend</code></pre>"

      assert round_trip(source) == source
    end

    test "never contains the character used to carry whitespace" do
      # An unclosed `<pre>` escapes the region the separator skips, and it
      # would otherwise be stored — invisible on the page and a real
      # character in the database.
      document = import_html!("<p><p><pre>   </p></p>")

      refute inspect(document, binaries: :as_binaries) =~ "238, 128, 128"
      refute inspect(document, binaries: :as_binaries) =~ "238, 128, 129"
      refute document |> Coelho.to_text() |> String.contains?("\u{E000}")
    end
  end
end
