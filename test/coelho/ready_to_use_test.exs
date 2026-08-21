defmodule Coelho.ReadyToUseTest do
  use ExUnit.Case, async: false

  # Attaching an anonymous handler makes :telemetry log a note about it on
  # every attach, which is right and is not what these tests are about.
  @moduletag :capture_log

  alias Coelho.{Document, Schema}

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text), do: %{"type" => "text", "text" => text}
  defp image, do: %{"type" => "image", "attrs" => %{"src" => "/a.png"}}

  describe "blank?/2" do
    test "an empty document, however many empty blocks it has" do
      assert Coelho.blank?(doc([]))
      assert Coelho.blank?(doc([paragraph([])]))
      assert Coelho.blank?(doc([paragraph([]), paragraph([]), %{"type" => "bullet_list"}]))
    end

    test "text anywhere is not blank" do
      refute Coelho.blank?(doc([paragraph([text("x")])]))

      nested =
        doc([
          %{
            "type" => "blockquote",
            "content" => [paragraph([text("deep")])]
          }
        ])

      refute Coelho.blank?(nested)
    end

    test "a void node is not blank, which is the whole point" do
      # `text_length(document) == 0` is the obvious stand-in and gets both of
      # these wrong, in the direction that makes the block disappear.
      assert Document.text_length(doc([paragraph([image()])])) == 0
      refute Coelho.blank?(doc([paragraph([image()])]))

      assert Document.text_length(doc([%{"type" => "horizontal_rule"}])) == 0
      refute Coelho.blank?(doc([%{"type" => "horizontal_rule"}]))
    end

    test "asks the schema, so a node it does not declare counts for nothing" do
      restricted = Schema.restrict(Schema.default(), nodes: [:paragraph])

      refute Coelho.blank?(doc([paragraph([image()])]))
      assert Coelho.blank?(doc([paragraph([image()])]), restricted)
    end

    test "a paragraph of nothing but hard breaks is blank" do
      # What a pasted-then-emptied field usually leaves behind. An inline void
      # node declaring no attributes is punctuation between words, and a
      # document that is one break should not make a heading appear with
      # nothing under it.
      breaks = doc([paragraph([%{"type" => "hard_break"}, %{"type" => "hard_break"}])])

      assert Coelho.blank?(breaks)
      refute Coelho.blank?(doc([paragraph([%{"type" => "hard_break"}, text("x")])]))
    end

    test "what is not a document is blank" do
      for value <- [nil, "", %{}, [], 42], do: assert(Coelho.blank?(value))
    end
  end

  describe "to_safe_html/3" do
    test "renders what to_html/3 renders, in the shape a template will not escape" do
      {:ok, document} = Coelho.validate(doc([paragraph([text("a & b")])]))

      assert {:safe, iodata} = Coelho.to_safe_html(document)
      assert IO.iodata_to_binary(iodata) == Coelho.to_html(document)
    end

    test "reaches the page as markup, where the plain string reaches it as text" do
      {:ok, document} = Coelho.validate(doc([paragraph([text("a & b")])]))

      through = fn value ->
        value |> Phoenix.HTML.Engine.encode_to_iodata!() |> IO.iodata_to_binary()
      end

      assert through.(Coelho.to_safe_html(document)) == "<p>a &amp; b</p>"
      # Which is the mistake it exists to remove: forget `raw/1` and the
      # reader is shown the source of their own document.
      assert through.(Coelho.to_html(document)) == "&lt;p&gt;a &amp;amp; b&lt;/p&gt;"
    end

    test "renders nothing for a document that is not there" do
      # `nil` is what a nullable column holds, and what both stored types cast
      # an absent document to, so the one-liner in the README must not take
      # the page down on it.
      assert Coelho.to_safe_html(nil) == {:safe, []}
      assert Coelho.to_html(nil) == ""
    end

    test "takes the same options the rest of rendering takes" do
      {:ok, document} = Coelho.validate(doc([paragraph([text("x")])]))

      assert {:safe, iodata} =
               Coelho.to_safe_html(document, nodes: %{paragraph: {"div", []}})

      assert IO.iodata_to_binary(iodata) == "<div>x</div>"
    end
  end

  describe "telemetry" do
    setup do
      handler = "coelho-test-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:coelho, :validate, :stop],
            [:coelho, :render, :stop],
            [:coelho, :storage, :stop]
          ],
          fn event, measurements, metadata, _config ->
            send(parent, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "validation says how big the document was and whether it took" do
      {:ok, _document} = Coelho.validate(doc([paragraph([text("bonjour")])]))

      assert_receive {:telemetry, [:coelho, :validate, :stop], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.result == :ok
      assert metadata.errors == 0
      assert metadata.nodes == 3
      assert metadata.text_length == 7
    end

    test "and how many errors there were when it did not" do
      {:error, _errors} = Coelho.validate(doc([%{"type" => "script"}]))

      assert_receive {:telemetry, [:coelho, :validate, :stop], _measurements, metadata}
      assert metadata.result == :error
      assert metadata.errors == 1
    end

    test "rendering says how much came out" do
      {:ok, document} = Coelho.validate(doc([paragraph([text("x")])]))
      html = Coelho.to_html(document)

      assert_receive {:telemetry, [:coelho, :render, :stop], _measurements, metadata}
      assert metadata.bytes == byte_size(html)
    end

    test "storing says which storage and which key", %{} do
      root = Path.join(System.tmp_dir!(), "coelho-#{System.unique_integer([:positive])}")
      key = Coelho.Attachment.generate_key()

      on_exit(fn -> File.rm_rf!(root) end)

      :ok = Coelho.Storage.put(Coelho.Storage.Disk.new(root), key, {:binary, "bytes"})

      assert_receive {:telemetry, [:coelho, :storage, :stop], _measurements, metadata}
      assert metadata.storage == Coelho.Storage.Disk
      assert metadata.key == key
      assert metadata.result == :ok
    end

    test "and costs nothing to read, because it was settled when the schema was built" do
      schema = Schema.default()
      {microseconds, _} = :timer.tc(fn -> for _ <- 1..1000, do: Schema.fingerprint(schema) end)

      # Exporting and hashing the schema on every call measured 6.4 µs each,
      # on a path that runs per keystroke and per render.
      assert microseconds < 1_000
    end

    test "the schema travels as a fingerprint, not as a schema" do
      {:ok, _document} = Coelho.validate(doc([paragraph([text("x")])]))

      assert_receive {:telemetry, [:coelho, :validate, :stop], _measurements, metadata}
      assert is_integer(metadata.schema)
      assert metadata.schema == Schema.fingerprint(Schema.default())
    end
  end
end
