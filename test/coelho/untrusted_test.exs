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
               ~s(<span class="coelho-attachment-name">plan.pdf</span> Q3)

      assert inline(document, policy: :untrusted, context: refusing) ==
               ~s(<span class="coelho-attachment-name">plan.pdf</span> Q3)
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
  end

  def embed_attrs(node), do: [{"src", Render.safe_url(Render.attr(node, "url"))}]
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
