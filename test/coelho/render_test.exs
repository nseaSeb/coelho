defmodule Coelho.RenderTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Render, Schema}

  defp schema, do: Schema.default()

  defp render(document, opts \\ []) do
    {:ok, document} = Document.validate(document, schema())
    Render.to_html(document, schema(), opts)
  end

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  test "renders blocks and inline marks" do
    document =
      doc([
        %{"type" => "heading", "attrs" => %{"level" => 2}, "content" => [text("Title")]},
        paragraph([text("plain "), text("bold", [%{"type" => "bold"}])])
      ])

    assert render(document) == "<h2>Title</h2><p>plain <strong>bold</strong></p>"
  end

  test "escapes text" do
    document = doc([paragraph([text(~s|<script>alert("x") & 'y'</script>|)])])

    assert render(document) ==
             "<p>&lt;script&gt;alert(&quot;x&quot;) &amp; &#39;y&#39;&lt;/script&gt;</p>"
  end

  test "escapes attribute values" do
    mark = %{"type" => "link", "attrs" => %{"href" => "/a?b=1&c=\"2\""}}
    document = doc([paragraph([text("link", [mark])])])

    assert render(document) == ~s(<p><a href="/a?b=1&amp;c=&quot;2&quot;">link</a></p>)
  end

  test "the first mark of the list ends up outermost" do
    marks = [%{"type" => "bold"}, %{"type" => "italic"}]
    document = doc([paragraph([text("x", marks)])])

    assert render(document) == "<p><strong><em>x</em></strong></p>"
  end

  test "omits attributes whose value is nil" do
    document = doc([paragraph([%{"type" => "image", "attrs" => %{"src" => "/a.png"}}])])

    assert render(document) == ~s(<p><img src="/a.png"></p>)
  end

  test "renders void nodes without a closing tag" do
    document = doc([paragraph([text("a"), %{"type" => "hard_break"}, text("b")])])

    assert render(document) == "<p>a<br>b</p>"
  end

  test "renders a code block with its language class" do
    document =
      doc([
        %{
          "type" => "code_block",
          "attrs" => %{"language" => "elixir"},
          "content" => [text("1 + 1")]
        }
      ])

    assert render(document) == ~s(<pre><code class="language-elixir">1 + 1</code></pre>)
  end

  test "renders an ordered list start only when it is not 1" do
    item = %{"type" => "list_item", "content" => [paragraph([text("a")])]}

    assert render(doc([%{"type" => "ordered_list", "content" => [item]}])) ==
             "<ol><li><p>a</p></li></ol>"

    assert render(
             doc([%{"type" => "ordered_list", "attrs" => %{"start" => 3}, "content" => [item]}])
           ) ==
             ~s(<ol start="3"><li><p>a</p></li></ol>)
  end

  test "a node override replaces the schema rendering" do
    document = doc([paragraph([text("x")])])

    html =
      render(document,
        nodes: %{paragraph: fn _node, inner -> Render.tag("div", [{"class", "lead"}], inner) end}
      )

    assert html == ~s(<div class="lead">x</div>)
  end

  test "a mark override replaces the schema rendering" do
    document = doc([paragraph([text("x", [%{"type" => "bold"}])])])

    html = render(document, marks: %{bold: {"b", []}})

    assert html == "<p><b>x</b></p>"
  end

  test "refuses to render a node the schema does not know" do
    assert_raise ArgumentError, ~r/unknown node type "iframe"/, fn ->
      Render.to_html(doc([%{"type" => "iframe"}]), schema())
    end
  end

  describe "trusting the schema only so far" do
    test "never builds a tag name out of an attribute value" do
      # A row written under a looser schema still renders through today's
      # renderer, so the heading level is clamped rather than interpolated.
      document =
        doc([
          %{
            "type" => "heading",
            "attrs" => %{"level" => "1><script>alert(1)</script"},
            "content" => [text("x")]
          }
        ])

      assert Render.to_html(document, schema()) == "<h1>x</h1>"
    end

    test "renders a text node missing its text rather than crashing" do
      assert Render.to_html(doc([paragraph([%{"type" => "text"}])]), schema()) == "<p></p>"
    end
  end

  describe "overriding the text node" do
    test "a caller override applies to text like any other node" do
      document = doc([paragraph([text("hi")])])

      html =
        render(document,
          nodes: %{text: fn _node, inner -> Render.tag("span", [{"class", "t"}], inner) end}
        )

      assert html == ~s(<p><span class="t">hi</span></p>)
    end

    test "a schema level render on the text node is honoured" do
      schema =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [content: "inline*", group: "block", render: {"p", []}],
            text: [group: "inline", inline: true, text: true, render: {"span", []}]
          ]
        )

      document = doc([paragraph([text("hi")])])
      {:ok, document} = Document.validate(document, schema)

      assert Render.to_html(document, schema) == "<p><span>hi</span></p>"
    end
  end

  describe "stored documents are not trusted at render time" do
    # Coelho.Ecto.Type.load/3 deliberately never re-validates, so the
    # renderer is the last line of defence for rows written before the schema
    # tightened, by a direct database write, or under a looser schema.

    test "drops a javascript: image source instead of emitting it" do
      document =
        doc([paragraph([%{"type" => "image", "attrs" => %{"src" => "javascript:alert(1)"}}])])

      assert Render.to_html(document, schema()) == "<p><img></p>"
    end

    test "drops a javascript: link target instead of emitting it" do
      mark = %{"type" => "link", "attrs" => %{"href" => "javascript:alert(1)"}}
      document = doc([paragraph([text("click", [mark])])])

      assert Render.to_html(document, schema()) == "<p><a>click</a></p>"
    end

    test "keeps a URL that is actually safe" do
      document = doc([paragraph([%{"type" => "image", "attrs" => %{"src" => "/a.png"}}])])

      assert Render.to_html(document, schema()) == ~s(<p><img src="/a.png"></p>)
    end

    test "a non-binary code block language degrades instead of crashing" do
      document =
        doc([
          %{"type" => "code_block", "attrs" => %{"language" => 123}, "content" => [text("x")]}
        ])

      assert Render.to_html(document, schema()) == "<pre><code>x</code></pre>"
    end
  end

  describe "childless elements" do
    test "the tags HTML closes by itself are emitted unclosed" do
      assert Render.void_tag("img", [{"src", "/a.png"}]) |> IO.iodata_to_binary() ==
               ~s(<img src="/a.png">)

      assert Render.void_tag("br", []) |> IO.iodata_to_binary() == "<br>"
    end

    test "anything else is closed, even with no children" do
      # An unclosed <span> swallows the rest of the paragraph in the
      # browser's parser, and a schema extension reaching for a `void: true`
      # inline node is exactly how that happens.
      assert Render.void_tag("span", [{"class", "mention"}]) |> IO.iodata_to_binary() ==
               ~s(<span class="mention"></span>)
    end
  end
end
