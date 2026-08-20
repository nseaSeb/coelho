defmodule Coelho.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Coelho.{Attachments, Document, Render, Schema}

  defp schema, do: Schema.default()

  defp attachment(attrs), do: %{"type" => "attachment", "attrs" => attrs}

  defp doc(content), do: %{"type" => "doc", "content" => content}

  defp validated(content) do
    {:ok, document} = Document.validate(doc(content), schema())
    document
  end

  describe "keys/2" do
    test "collects every referenced key, in document order, without repeats" do
      document =
        validated([
          attachment(%{"key" => "a", "filename" => "a.pdf"}),
          %{
            "type" => "blockquote",
            "content" => [attachment(%{"key" => "b", "filename" => "b.pdf"})]
          },
          attachment(%{"key" => "a", "filename" => "a.pdf"})
        ])

      assert Attachments.keys(document, schema()) == ["a", "b"]
    end

    test "finds attachment-like nodes of a custom schema by their :key attribute" do
      schema =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            file: [group: "block", void: true, attrs: [key: [required: true, validate: :string]]]
          ]
        )

      document = %{
        "type" => "doc",
        "content" => [%{"type" => "file", "attrs" => %{"key" => "k"}}]
      }

      assert Attachments.keys(document, schema) == ["k"]
    end

    test "a document without attachments has no keys" do
      document = validated([%{"type" => "paragraph", "content" => []}])

      assert Attachments.keys(document, schema()) == []
    end
  end

  describe "resolving at render time" do
    test "a resolver function turns the key into a URL" do
      document =
        validated([
          attachment(%{"key" => "k", "filename" => "a.png", "content_type" => "image/png"})
        ])

      html =
        Render.to_html(document, schema(), context: %{resolve: fn "k" -> "/files/k?sig=1" end})

      # A nil attribute is dropped, here as everywhere else.
      assert html == ~s(<figure class="coelho-attachment"><img src="/files/k?sig=1"></figure>)
    end

    test "a map of already loaded URLs works as a resolver" do
      document = validated([attachment(%{"key" => "k", "filename" => "a.pdf"})])

      html = Render.to_html(document, schema(), context: %{resolve: %{"k" => "/files/k"}})

      assert html =~ ~s(<a href="/files/k">a.pdf</a>)
    end

    test "the same document renders a different URL on the next render" do
      # This is the whole reason the URL is not stored: a five minute signed
      # URL would be as old as the document if it were.
      document = validated([attachment(%{"key" => "k", "filename" => "a.pdf"})])

      first = Render.to_html(document, schema(), context: %{resolve: %{"k" => "/k?exp=1"}})
      second = Render.to_html(document, schema(), context: %{resolve: %{"k" => "/k?exp=2"}})

      assert first =~ "exp=1"
      assert second =~ "exp=2"
    end

    test "a key that no longer resolves degrades to its filename" do
      document = validated([attachment(%{"key" => "gone", "filename" => "a.pdf"})])

      html = Render.to_html(document, schema(), context: %{resolve: fn _ -> nil end})

      assert html =~ ~s(<span class="coelho-attachment-missing">a.pdf</span>)
      refute html =~ "<img"
    end

    test "renders nothing resolvable when no context is given at all" do
      document = validated([attachment(%{"key" => "k", "filename" => "a.pdf"})])

      assert Render.to_html(document, schema()) =~ "coelho-attachment-missing"
    end

    test "a resolver returning a javascript: URL is still refused" do
      document = validated([attachment(%{"key" => "k", "filename" => "a.pdf"})])

      html =
        Render.to_html(document, schema(), context: %{resolve: fn _ -> "javascript:alert(1)" end})

      refute html =~ "javascript:"
      assert html =~ "coelho-attachment-missing"
    end

    test "escapes the filename and the caption" do
      document =
        validated([
          attachment(%{"key" => "k", "filename" => "<script>", "caption" => "a & b"})
        ])

      html = Render.to_html(document, schema(), context: %{resolve: %{"k" => "/k"}})

      assert html =~ "&lt;script&gt;"
      assert html =~ "<figcaption>a &amp; b</figcaption>"
    end
  end

  describe "validation and text" do
    test "an attachment without a key is rejected" do
      assert {:error, _} =
               Document.validate(doc([attachment(%{"filename" => "a.pdf"})]), schema())
    end

    test "the document stores no URL, whatever the client sends" do
      assert {:error, [error]} =
               Document.validate(doc([attachment(%{"key" => "k", "url" => "/k"})]), schema())

      assert Coelho.Document.Error.format(error) =~ ~s(unknown attribute "url")
    end

    test "plain text extraction names the attachment" do
      document = validated([attachment(%{"key" => "k", "filename" => "plan.pdf"})])

      assert Document.to_text(document, schema()) == "plan.pdf"
    end
  end

  describe "orphans/3" do
    test "answers what is stored and no longer referred to" do
      documents = [validated([attachment(%{"key" => "kept", "filename" => "a.pdf"})])]

      assert Attachments.orphans(["kept", "gone", "never used"], documents) ==
               ["gone", "never used"]
    end

    test "a key referred to by any document survives" do
      documents = [
        validated([%{"type" => "paragraph", "content" => []}]),
        validated([attachment(%{"key" => "kept", "filename" => "a.pdf"})])
      ]

      assert Attachments.orphans(["kept"], documents) == []
    end

    test "an empty column is not a document with no attachments" do
      # A nil body means "no rich text here", and treating it as an empty
      # document would be the same answer for the wrong reason. Either way it
      # must not make something look unused.
      documents = [nil, validated([attachment(%{"key" => "kept", "filename" => "a.pdf"})])]

      assert Attachments.orphans(["kept"], documents) == []
    end

    test "nothing stored means nothing to remove" do
      assert Attachments.orphans([], [Coelho.empty()]) == []
    end
  end

  describe "sweep/4" do
    @moduletag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      storage = Coelho.Storage.Disk.new(tmp_dir)

      for key <- ~w(kept gone) do
        :ok = Coelho.Storage.put(storage, key, {:binary, key})
      end

      %{storage: storage}
    end

    test "removes what no document refers to, and says what went", %{storage: storage} do
      documents = [validated([attachment(%{"key" => "kept", "filename" => "a.pdf"})])]

      assert {:ok, ["gone"]} = Attachments.sweep(storage, ~w(kept gone), documents)
      assert Coelho.Storage.exists?(storage, "kept")
      refute Coelho.Storage.exists?(storage, "gone")
    end

    test "a dry run touches nothing", %{storage: storage} do
      documents = [validated([attachment(%{"key" => "kept", "filename" => "a.pdf"})])]

      assert {:ok, ["gone"]} =
               Attachments.sweep(storage, ~w(kept gone), documents, dry_run: true)

      assert Coelho.Storage.exists?(storage, "gone")
    end

    test "stops at the first refusal rather than carrying on", %{storage: storage} do
      # A key the storage will not touch means something is wrong with the
      # list it was given; deleting the rest of it on that footing is how a
      # cleanup job becomes an incident.
      assert {:error, {"../escaped", :invalid_key}} =
               Attachments.sweep(storage, ["../escaped", "gone"], [])

      assert Coelho.Storage.exists?(storage, "gone")
    end
  end
end
