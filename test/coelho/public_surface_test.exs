defmodule Coelho.PublicSurfaceTest do
  use ExUnit.Case, async: true

  alias Coelho.{Attachments, Document, Render, Schema, Storage}

  # Coverage said it out loud: several functions of the module every consumer
  # calls first were never run by any test — `canonical/1`, `sanitize/3`,
  # `text_length/1`, `to_safe_html/2`, `to_inline_html/2`. They are one-line
  # delegates, which is exactly why nobody wrote a test: a delegate cannot go
  # wrong. It can point at the wrong function, take its arguments in the
  # wrong order, or lose an option on the way through, and the compiler is
  # happy with all three.

  defp schema, do: Schema.default()

  defp document do
    %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "heading",
          "attrs" => %{"level" => 2},
          "content" => [%{"type" => "text", "text" => "Title"}]
        },
        %{
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "text" => "a "},
            %{"type" => "text", "text" => "link", "marks" => [%{"type" => "bold"}]}
          ]
        }
      ]
    }
  end

  describe "every delegate answers what it delegates to" do
    test "the document functions" do
      {:ok, valid} = Document.validate(document(), schema())

      assert Coelho.validate(document()) == Document.validate(document(), schema())
      assert Coelho.canonical(valid) == Document.canonical(valid)
      assert Coelho.hash(valid) == Document.hash(valid)
      assert Coelho.hash(valid, :sha512) == Document.hash(valid, :sha512)
      assert Coelho.text_length(valid) == Document.text_length(valid)
      assert Coelho.to_text(valid) == Document.to_text(valid, schema())
      assert Coelho.empty() == Schema.empty(schema())
    end

    test "sanitising, with and without options" do
      hostile = %{"type" => "doc", "content" => [%{"type" => "nonsense"}]}

      assert Coelho.sanitize(hostile) == Document.sanitize(hostile, schema())

      long = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "abcdef"}]}
        ]
      }

      opts = [limits: [max_text_length: 3]]

      # The option has to survive the delegate: losing it silently would
      # store six characters where the caller asked for three.
      assert Coelho.sanitize(long, schema(), opts) == Document.sanitize(long, schema(), opts)
      assert Coelho.text_length(Coelho.sanitize(long, schema(), opts)) == 3
    end

    test "the render functions, in all four shapes" do
      {:ok, valid} = Document.validate(document(), schema())

      assert Coelho.to_html(valid) == Render.to_html(valid, schema(), [])
      assert Coelho.to_html(valid, schema()) == Render.to_html(valid, schema(), [])
      assert Coelho.to_safe_html(valid) == Render.to_safe_html(valid, schema(), [])
      assert Coelho.to_safe_html(valid, schema()) == Render.to_safe_html(valid, schema(), [])
      assert Coelho.to_inline_html(valid) == Render.to_inline_html(valid, schema(), [])
      assert Coelho.to_inline_html(valid, schema()) == Render.to_inline_html(valid, schema(), [])

      assert Coelho.to_safe_inline_html(valid) == Render.to_safe_inline_html(valid, schema(), [])

      assert Coelho.to_safe_inline_html(valid, schema()) ==
               Render.to_safe_inline_html(valid, schema(), [])

      # And the option reaches the renderer rather than being dropped.
      assert Coelho.to_inline_html(valid, schema(), separator: " — ") =~ " — "
      assert {:safe, iodata} = Coelho.to_safe_inline_html(valid, separator: " — ")
      assert IO.iodata_to_binary(iodata) == "Title — a <strong>link</strong>"
    end

    test "iodata, which is what a template wants when it is composing" do
      {:ok, valid} = Document.validate(document(), schema())

      assert valid |> Render.to_iodata(schema()) |> IO.iodata_to_binary() ==
               Render.to_html(valid, schema())

      assert valid |> Render.to_inline_iodata(schema()) |> IO.iodata_to_binary() ==
               Render.to_inline_html(valid, schema())
    end

    test "the import, with and without its options" do
      html = "<p>a</p>"

      assert Coelho.from_html(html) == Coelho.HTML.from_html(html, schema(), [])

      assert Coelho.from_html(html, schema(), warnings: false) ==
               Coelho.HTML.from_html(html, schema(), warnings: false)
    end
  end

  describe "migrating between schema versions" do
    test "a document written under an old vocabulary is read by the new one" do
      # `migrate/2` was documented, specified and never once run end to end:
      # a document written under one schema, migrated, and accepted by the
      # other. Everything below is what an application would actually do.
      old =
        Schema.new(
          version: 1,
          nodes: [
            doc: [content: "block+"],
            paragraph: [content: "text*", group: "block", render: {"p", []}],
            callout: [content: "text*", group: "block", render: {"aside", []}]
          ]
        )

      new =
        Schema.new(
          version: 2,
          nodes: [
            doc: [content: "block+"],
            paragraph: [content: "text*", group: "block", render: {"p", []}],
            notice: [
              content: "text*",
              group: "block",
              attrs: [tone: [default: "info", validate: {:one_of, ~w(info warning)}]],
              render: {"aside", []}
            ]
          ]
        )

      stored = %{
        "type" => "doc",
        "content" => [
          %{"type" => "callout", "content" => [%{"type" => "text", "text" => "watch out"}]}
        ]
      }

      {:ok, stored} = Document.validate(stored, old)
      assert stored["schema_version"] == 1

      # The new schema refuses it, which is the whole reason a version exists.
      assert {:error, _} = Document.validate(stored, new)

      rename = fn document ->
        update_in(document["content"], fn blocks ->
          Enum.map(blocks, fn
            %{"type" => "callout"} = block -> %{block | "type" => "notice"}
            block -> block
          end)
        end)
      end

      assert {:ok, migrated} = Coelho.migrate(stored, from: 1, to: 2, with: %{2 => rename})
      assert {:ok, accepted} = Document.validate(migrated, new)
      assert accepted["schema_version"] == 2
      assert Coelho.to_html(accepted, new) == "<aside>watch out</aside>"

      # And running it again is refused rather than silently reapplied: the
      # stamp is what tells a migrated document from one that never was.
      assert {:error, _} = Coelho.migrate(accepted, from: 1, to: 2, with: %{2 => rename})
    end

    test "a document already at the target version is handed back untouched" do
      document = %{"type" => "doc", "schema_version" => 2, "content" => []}

      assert {:ok, ^document} = Coelho.migrate(document, from: 2, to: 2, with: %{})
    end

    test "a step is run per version, in order, and the stamp follows" do
      document = %{"type" => "doc", "schema_version" => 1, "content" => []}

      steps = %{
        2 => fn doc -> Map.put(doc, "one", true) end,
        3 => fn doc -> Map.put(doc, "two", true) end
      }

      assert {:ok, migrated} = Coelho.migrate(document, from: 1, to: 3, with: steps)
      assert migrated["one"] and migrated["two"]
      assert migrated["schema_version"] == 3
    end

    test "a document stamped with another version is refused rather than migrated" do
      document = %{"type" => "doc", "schema_version" => 5, "content" => []}

      assert {:error, _reason} = Coelho.migrate(document, from: 1, to: 2, with: %{2 => & &1})
    end

    test "migrating backwards is refused" do
      assert {:error, _reason} = Coelho.migrate(%{"type" => "doc"}, from: 3, to: 1, with: %{})
    end

    test "a version that is not one is refused loudly, since it is the caller's own" do
      assert_raise ArgumentError, fn ->
        Coelho.migrate(%{"type" => "doc"}, from: "1", to: 2, with: %{})
      end
    end
  end

  describe "attachments" do
    test "keys reads the shipped schema when it is not given one" do
      document = %{
        "type" => "doc",
        "content" => [
          %{"type" => "attachment", "attrs" => %{"key" => "one"}},
          %{"type" => "attachment", "attrs" => %{"key" => "two"}}
        ]
      }

      assert Attachments.keys(document) == ["one", "two"]
    end

    test "a URL is resolved from a map, from a function, or from nothing at all" do
      assert Attachments.resolve(%{resolve: %{"k" => "/one"}}, "k") == "/one"
      assert Attachments.resolve(%{resolve: fn key -> "/fun/" <> key end}, "k") == "/fun/k"
      assert Attachments.resolve(fn key -> "/bare/" <> key end, "k") == "/bare/k"
      assert Attachments.resolve(%{}, "k") == nil
      assert Attachments.resolve(%{resolve: %{}}, nil) == nil
      assert Attachments.resolve("not a resolver", "k") == nil
    end
  end

  describe "a storage that hands out its own URL" do
    defmodule Presigned do
      @moduledoc false
      @behaviour Coelho.Storage

      defstruct []

      @impl true
      def put(_storage, _key, _source), do: :ok
      @impl true
      def read(_storage, _key), do: {:error, :enoent}
      @impl true
      def path(_storage, _key), do: :error
      @impl true
      def delete(_storage, _key), do: :ok
      @impl true
      def exists?(_storage, _key), do: true
      @impl true
      def redirect_url(_storage, key, opts),
        do: {:ok, "https://bucket.test/#{key}?#{inspect(opts)}"}
    end

    defmodule Plain do
      @moduledoc false
      @behaviour Coelho.Storage

      defstruct []

      @impl true
      def put(_storage, _key, _source), do: :ok
      @impl true
      def read(_storage, _key), do: {:ok, "bytes"}
      @impl true
      def path(_storage, _key), do: :error
      @impl true
      def delete(_storage, _key), do: :ok
      @impl true
      def exists?(_storage, _key), do: true
    end

    test "answers a URL through the wrapper, options and all" do
      assert {:ok, url} = Storage.redirect_url(%Presigned{}, "k", content_type: "image/png")
      assert url =~ "https://bucket.test/k"
      assert url =~ "image/png"
    end

    test "and a storage without one says so rather than raising" do
      assert Storage.redirect_url(%Plain{}, "k") == :error
      assert Storage.stream(%Plain{}, "k") == :error
    end
  end

  describe "what a validator says when the value is the wrong kind" do
    # These messages are what a form shows a writer, and coverage said every
    # refusal branch was unreached: the validators had only ever been asked
    # about values they accept.
    alias Coelho.Schema.Attr

    test "each kind refuses what it is not, in its own words" do
      assert Attr.validate(:string, 1) == {:error, "must be a string"}
      assert Attr.validate(:integer, "1") == {:error, "must be an integer"}
      assert Attr.validate(:boolean, "true") == {:error, "must be a boolean"}
      assert Attr.validate(:safe_url, 1) == {:error, "must be a string"}
      assert {:error, _} = Attr.validate({:one_of, ~w(a b)}, "c")
    end

    test "each kind accepts what it is" do
      assert Attr.validate(:string, "a") == :ok
      assert Attr.validate(:integer, 1) == :ok
      assert Attr.validate(:boolean, true) == :ok
      assert Attr.validate(:boolean, false) == :ok
      assert Attr.validate(:safe_url, "https://example.test") == :ok
      assert Attr.validate({:nullable, :string}, nil) == :ok
    end

    test "no validator at all accepts anything, which is what declaring none means" do
      assert Attr.validate(nil, %{"anything" => [1, 2, 3]}) == :ok
    end
  end

  describe "what an error says to a person" do
    # `Coelho.Document.Error.humanize/1` is what an application puts in a
    # form. Coverage said the branches for a mark, for a whole attribute map,
    # and for a document with no blocks had never run — so nobody had ever
    # seen those sentences.
    test "names the block, the attribute and the formatting" do
      {:error, errors} =
        Document.validate(
          %{
            "type" => "doc",
            "content" => [
              %{
                "type" => "paragraph",
                "attrs" => "not a map",
                "content" => [
                  %{"type" => "text", "text" => "x", "marks" => [%{"type" => "nonsense"}]}
                ]
              }
            ]
          },
          schema()
        )

      said = Enum.map_join(errors, " | ", &Coelho.Document.Error.humanize/1)

      assert said =~ "block 1"
      assert said =~ "its attributes"
      assert said =~ "formatting"
    end

    test "an error at the root of an empty document still reads as a sentence" do
      {:error, [error | _]} = Document.validate(%{"type" => "nonsense"}, schema())

      said = Coelho.Document.Error.humanize(error)

      # No block to name, so what it points at is the document itself.
      assert said == "the document: unknown node type \"nonsense\""
    end
  end

  describe "inserting a node from the server" do
    test "pushes the event the hook listens for, with the node and the preview" do
      socket = %Phoenix.LiveView.Socket{}

      node = %{"type" => "attachment", "attrs" => %{"key" => "k"}}

      pushed =
        Coelho.LiveView.insert_node(socket, node, id: "post_body-editor", preview: "/preview/k")

      assert %{private: %{live_temp: %{push_events: [["coelho:insert", payload]]}}} = pushed
      assert payload.node == node
      assert payload.id == "post_body-editor"
      assert payload.preview == "/preview/k"
    end
  end

  describe "telemetry" do
    test "says whether it is emitting" do
      # Compiled one way or the other depending on whether `:telemetry` is
      # there; in this project it is.
      assert Coelho.Telemetry.enabled?()
    end
  end
end
