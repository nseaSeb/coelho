defmodule Coelho.UntrustedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Coelho.{Document, Render, Schema}

  import Coelho.Test.Documents

  defp schema, do: Schema.default()

  # A resolver that answers for every key, so that a trusted render of an
  # attachment does carry a URL and the untrusted one has something to drop.
  @context %{resolve: &__MODULE__.url/1}

  def url(key), do: "/files/" <> key

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}

  defp link(text, href),
    do: %{
      "type" => "text",
      "text" => text,
      "marks" => [%{"type" => "link", "attrs" => %{"href" => href}}]
    }

  defp image(attrs), do: %{"type" => "image", "attrs" => attrs}
  defp attachment(attrs), do: %{"type" => "attachment", "attrs" => attrs}

  defp render(document, opts) do
    {:ok, document} = Document.validate(document, schema())
    Render.to_html(document, schema(), Keyword.put_new(opts, :context, @context))
  end

  defp inline(document, opts) do
    {:ok, document} = Document.validate(document, schema())
    Render.to_inline_html(document, schema(), Keyword.put_new(opts, :context, @context))
  end

  describe "the default schema under policy: :untrusted" do
    test "a link is its text" do
      document = doc([paragraph([link("go there", "https://example.com")])])

      assert render(document, []) == ~s(<p><a href="https://example.com">go there</a></p>)
      assert render(document, policy: :untrusted) == "<p>go there</p>"
    end

    test "an image is its alt text, and nothing when it has none" do
      document = doc([paragraph([image(%{"src" => "/cat.png", "alt" => "a <cat>"})])])

      assert render(document, policy: :untrusted) ==
               ~s(<p><span class="coelho-image-alt">a &lt;cat&gt;</span></p>)

      bare = doc([paragraph([image(%{"src" => "/cat.png"})])])
      assert render(bare, policy: :untrusted) == "<p></p>"
    end

    test "an attachment is its file name and caption, and its URL is never resolved" do
      document = doc([attachment(%{"key" => "k1", "filename" => "plan.pdf", "caption" => "Q3"})])
      refusing = %{resolve: fn key -> flunk("resolved #{key} under :untrusted") end}

      assert render(document, policy: :untrusted, context: refusing) ==
               ~s(<figure class="coelho-attachment"><span class="coelho-attachment-name">plan.pdf</span><figcaption>Q3</figcaption></figure>)

      assert inline(document, policy: :untrusted, context: refusing) ==
               ~s(<span class="coelho-attachment-name">plan.pdf</span> Q3)
    end

    # Documented in the README rather than resolved: `blank?/2` answers for
    # the document, not for one way of rendering it.
    test "an image with no alt renders nothing, and the document is still not blank" do
      document = doc([paragraph([image(%{"src" => "/cat.png"})])])

      refute Coelho.blank?(document)
      assert inline(document, policy: :untrusted) == ""
    end

    test "two attachments in a row stay two on the page and inline" do
      document =
        doc([
          attachment(%{"key" => "a", "filename" => "a.pdf"}),
          attachment(%{"key" => "b", "filename" => "b.pdf"})
        ])

      assert render(document, policy: :untrusted) ==
               ~s(<figure class="coelho-attachment"><span class="coelho-attachment-name">a.pdf</span></figure>) <>
                 ~s(<figure class="coelho-attachment"><span class="coelho-attachment-name">b.pdf</span></figure>)

      refute inline(document, policy: :untrusted) =~ "figure"
      assert inline(document, policy: :untrusted) =~ "a.pdf</span> <span"
    end

    test "inline rendering does not fall back to :render_inline" do
      document = doc([attachment(%{"key" => "k1", "filename" => "plan.pdf"})])

      assert inline(document, []) =~ ~s(href="/files/k1")
      refute inline(document, policy: :untrusted) =~ "href"
    end

    test "what does not point anywhere is untouched" do
      document =
        doc([
          %{
            "type" => "heading",
            "attrs" => %{"level" => 2},
            "content" => [%{"type" => "text", "text" => "T"}]
          },
          paragraph([%{"type" => "text", "text" => "b", "marks" => [%{"type" => "bold"}]}])
        ])

      assert render(document, policy: :untrusted) == render(document, [])
    end

    test "every node the shipped schema renders through a function says what it shows untrusted" do
      schema = Coelho.Schema.Default.build(tables: true)

      for {name, spec} <- Enum.concat(schema.nodes, schema.marks), is_function(spec.render) do
        assert spec.render_untrusted, "#{name} would render as its children under :untrusted"
      end
    end

    # The allow list's other side: everything the shipped schema draws that
    # points nowhere comes through untouched — spans, a list's start, an
    # alignment's style, every inline mark but the link.
    test "markup that points nowhere is the same trusted and untrusted" do
      schema = Coelho.Schema.Default.build(tables: true)
      t = fn text, marks -> %{"type" => "text", "text" => text, "marks" => marks} end

      cell = fn type, attrs ->
        %{"type" => type, "attrs" => attrs, "content" => [paragraph([t.("c", [])])]}
      end

      document =
        doc([
          %{
            "type" => "heading",
            "attrs" => %{"level" => 3, "align" => "center"},
            "content" => [t.("h", [%{"type" => "bold"}, %{"type" => "italic"}])]
          },
          %{
            "type" => "paragraph",
            "attrs" => %{"align" => "right"},
            "content" => [
              t.("s", [%{"type" => "strike"}]),
              %{"type" => "hard_break"},
              t.("x", [%{"type" => "code"}])
            ]
          },
          %{
            "type" => "ordered_list",
            "attrs" => %{"start" => 4},
            "content" => [
              %{
                "type" => "list_item",
                "attrs" => %{"align" => "justify"},
                "content" => [paragraph([t.("i", [])])]
              }
            ]
          },
          %{"type" => "blockquote", "content" => [paragraph([t.("q", [])])]},
          %{"type" => "horizontal_rule"},
          %{
            "type" => "table",
            "content" => [
              %{
                "type" => "table_row",
                "content" => [
                  cell.("table_header", %{"colspan" => 2}),
                  cell.("table_cell", %{"rowspan" => 3})
                ]
              }
            ]
          }
        ])

      {:ok, document} = Document.validate(document, schema)
      trusted = Render.to_html(document, schema)

      for fragment <-
            ~w(colspan="2" rowspan="3" start="4" text-align:center text-align:justify <hr <br <s> <code>) do
        assert trusted =~ fragment, "the premise: #{fragment} in #{trusted}"
      end

      assert Render.to_html(document, schema, policy: :untrusted) == trusted

      assert Render.to_inline_html(document, schema, policy: :untrusted) ==
               Render.to_inline_html(document, schema)
    end

    test "a code block keeps its markup" do
      document =
        doc([
          %{
            "type" => "code_block",
            "attrs" => %{"language" => "elixir"},
            "content" => [%{"type" => "text", "text" => "x = 1"}]
          }
        ])

      assert render(document, policy: :untrusted) == render(document, [])
    end
  end

  describe "who decides" do
    test "the caller's override wins over the policy" do
      document = doc([paragraph([link("go", "/here")])])
      marks = %{link: {"a", [{"href", "/elsewhere"}]}}

      assert render(document, policy: :untrusted, marks: marks) ==
               ~s(<p><a href="/elsewhere">go</a></p>)
    end

    test "an override of nil is children only, under either policy" do
      document = doc([paragraph([link("go", "/here")])])

      assert render(document, marks: %{link: nil}) == "<p>go</p>"
      assert render(document, policy: :untrusted, marks: %{link: nil}) == "<p>go</p>"
    end

    test "an unknown policy raises rather than rendering as trusted" do
      document = doc([paragraph([link("go", "/here")])])

      assert_raise ArgumentError, ~r/unknown render policy :untursted/, fn ->
        render(document, policy: :untursted)
      end

      assert_raise ArgumentError, ~r/unknown render policy/, fn ->
        inline(document, policy: "untrusted")
      end
    end
  end

  describe "a schema the policy has never seen" do
    setup do
      schema =
        Schema.extend(Schema.default(),
          nodes: [
            embed: [
              group: "block",
              void: true,
              attrs: [url: [required: true, validate: {:nullable, :safe_url}]],
              render: {"iframe", &__MODULE__.embed_attrs/1},
              render_inline: {"a", &__MODULE__.embed_link/1}
            ],
            card: [
              group: "block",
              void: true,
              attrs: [id: [required: true, validate: :string]],
              render: {"a", &__MODULE__.card_attrs/1},
              render_untrusted: &__MODULE__.untrusted_card/2
            ],
            panel: [
              group: "block",
              content: "inline*",
              attrs: [ref: [required: true, validate: :string]],
              render: {"aside", []},
              render_inline: {"a", &__MODULE__.panel_link/1},
              render_untrusted: {"div", []}
            ]
          ],
          marks: [
            cite: [
              attrs: [source: [required: true, validate: :safe_url]],
              render: {"q", &__MODULE__.cite_attrs/1}
            ]
          ]
        )

      %{schema: schema}
    end

    test "a node or mark with a :safe_url attribute loses it without declaring anything",
         %{schema: schema} do
      document =
        doc([
          %{"type" => "embed", "attrs" => %{"url" => "https://video.example/1"}},
          paragraph([
            %{
              "type" => "text",
              "text" => "said",
              "marks" => [%{"type" => "cite", "attrs" => %{"source" => "/s"}}]
            }
          ])
        ])

      {:ok, document} = Document.validate(document, schema)

      assert Render.to_html(document, schema) =~ "iframe"
      assert Render.to_html(document, schema, policy: :untrusted) == "<p>said</p>"

      # `nil` from the policy is "children only", not "no inline form of its
      # own": the embed's `:render_inline` would put the URL back.
      assert Render.to_inline_html(document, schema) =~ ~s(href="https://video.example/1")
      assert Render.to_inline_html(document, schema, policy: :untrusted) == "said"
    end

    test "a node that points somewhere without a URL attribute says what it shows",
         %{schema: schema} do
      {:ok, document} =
        Document.validate(doc([%{"type" => "card", "attrs" => %{"id" => "7"}}]), schema)

      assert Render.to_html(document, schema) == ~s(<a href="/cards/7"></a>)
      assert Render.to_html(document, schema, policy: :untrusted) == "card 7"
    end

    test "a block node's untrusted form never reaches the inline renderer, nor does its trusted inline form",
         %{schema: schema} do
      panel = %{
        "type" => "panel",
        "attrs" => %{"ref" => "p1"},
        "content" => [%{"type" => "text", "text" => "hi"}]
      }

      {:ok, document} = Document.validate(doc([panel]), schema)

      assert Render.to_inline_html(document, schema) == ~s(<a href="/panels/p1">hi</a>)
      assert Render.to_html(document, schema, policy: :untrusted) == "<div>hi</div>"
      assert Render.to_inline_html(document, schema, policy: :untrusted) == "hi"
    end
  end

  def embed_attrs(node), do: [{"src", Render.safe_url(Render.attr(node, "url"))}]

  test "an untrusted inline form without a page form is refused when the schema is built" do
    assert_raise ArgumentError, ~r/:mention has :render_untrusted_inline without/, fn ->
      Schema.extend(Schema.default(),
        nodes: [
          mention: [
            group: "inline",
            inline: true,
            void: true,
            attrs: [user: [required: true, validate: :string]],
            render: {"a", []},
            render_untrusted_inline: &__MODULE__.untrusted_card/2
          ]
        ]
      )
    end
  end

  test "redeclaring one half is judged against the merged spec" do
    # Only the inline half: the page half the default declares is kept.
    schema =
      Schema.extend(Schema.default(),
        nodes: [attachment: [render_untrusted_inline: &__MODULE__.untrusted_card/2]]
      )

    assert schema.nodes.attachment.render_untrusted ==
             Schema.default().nodes.attachment.render_untrusted

    # Taking the page half away leaves the default's inline half alone.
    assert_raise ArgumentError, ~r/:attachment has :render_untrusted_inline without/, fn ->
      Schema.extend(Schema.default(), nodes: [attachment: [render_untrusted: nil]])
    end
  end

  # A URL attribute reduces a node to its children in both renderers, whatever
  # shape its validator takes, so that the page and an excerpt of it agree.
  # Without the rule a `{tag, attrs}` form would still be safe — its
  # attributes are filtered — but would leave an empty element behind.
  for validator <- [:safe_url, {:nullable, :safe_url}] do
    test "a URL attribute validated as #{inspect(validator)} is children only, page and inline" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [
            chip: [
              group: "inline",
              inline: true,
              content: "text*",
              attrs: [u: [required: true, validate: unquote(Macro.escape(validator))]],
              render: {"span", [{"class", "chip"}]},
              render_inline: {"span", [{"class", "chip"}]}
            ]
          ]
        )

      chip = %{
        "type" => "chip",
        "attrs" => %{"u" => "/x"},
        "content" => [%{"type" => "text", "text" => "c"}]
      }

      {:ok, document} = Document.validate(doc([paragraph([chip])]), schema)

      assert Render.to_html(document, schema, policy: :untrusted) == "<p>c</p>"
      assert Render.to_inline_html(document, schema, policy: :untrusted) == "c"
    end
  end

  test "a {tag, attrs} render keeps what cannot fetch and drops the rest" do
    schema =
      Schema.extend(Schema.default(),
        nodes: [
          badge: [
            group: "inline",
            inline: true,
            content: "text*",
            class: "badge",
            attrs: [
              tone: [
                default: "plain",
                validate: {:one_of, ~w(plain loud)},
                render_as: {:style, "color"}
              ]
            ],
            render:
              {"span",
               [
                 {"aria-label", "a"},
                 {"data-k", "v"},
                 {"title", "t"},
                 {"id", "shadow"},
                 {"style", "x:u\\rl(/p)"},
                 {"Class", "upper"},
                 {"onclick", "go()"}
               ]}
          ]
        ]
      )

    badge = %{
      "type" => "badge",
      "attrs" => %{"tone" => "loud"},
      "content" => [%{"type" => "text", "text" => "b"}]
    }

    {:ok, document} = Document.validate(doc([paragraph([badge])]), schema)

    assert Render.to_html(document, schema, policy: :untrusted) ==
             ~s(<p><span aria-label="a" title="t" style="color:loud" class="badge">b</span></p>)
  end

  test "an inline node whose declared inline form cannot run untrusted is its children inline" do
    schema =
      Schema.extend(Schema.default(),
        nodes: [
          card_mention: [
            group: "inline",
            inline: true,
            content: "text*",
            render: {"div", [{"class", "card"}]},
            render_inline: &__MODULE__.untrusted_card_inline/2
          ]
        ]
      )

    node = %{"type" => "card_mention", "content" => [%{"type" => "text", "text" => "m"}]}
    {:ok, document} = Document.validate(doc([paragraph([node])]), schema)

    assert Render.to_inline_html(document, schema) == "<b>m</b>"
    assert Render.to_inline_html(document, schema, policy: :untrusted) == "m"
  end

  test "form controls and raw-text elements are their children" do
    for tag <-
          ~w(button select textarea option plaintext xmp listing noembed noframes noscript template title) do
      schema =
        Schema.extend(Schema.default(),
          nodes: [box: [group: "block", content: "inline*", render: {tag, [{"class", "k"}]}]]
        )

      box = %{"type" => "box", "content" => [%{"type" => "text", "text" => "x"}]}
      {:ok, document} = Document.validate(doc([box]), schema)

      assert Render.to_html(document, schema, policy: :untrusted) == "x", tag
    end
  end

  def untrusted_card_inline(_node, inner), do: Render.tag("b", [], inner)

  def panel_link(node), do: [{"href", "/panels/" <> Render.attr(node, "ref")}]
  def embed_link(node), do: [{"href", Render.safe_url(Render.attr(node, "url"))}]
  def cite_attrs(mark), do: [{"cite", Render.safe_url(Render.attr(mark, "source"))}]
  def card_attrs(node), do: [{"href", "/cards/" <> Render.attr(node, "id")}]
  def untrusted_card(node, _inner), do: Render.escape("card " <> Render.attr(node, "id"))

  # The promise, over every shape the generators make: nothing that loads or
  # follows anything, from either renderer. The attachment is included and
  # the resolver answers every key, so a trusted render of the same document
  # would carry both.
  property "an untrusted render carries no href and no src" do
    check all(document <- document()) do
      {:ok, document} = Document.validate(document, schema())

      for html <- [
            Render.to_html(document, schema(), context: @context, policy: :untrusted),
            Render.to_inline_html(document, schema(), context: @context, policy: :untrusted)
          ] do
        refute html =~ ~r/\s(href|src)=/
      end
    end
  end
end
