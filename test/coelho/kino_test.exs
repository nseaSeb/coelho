defmodule Coelho.KinoTest do
  use ExUnit.Case, async: true

  import Kino.Test

  alias Coelho.Schema

  setup :configure_livebook_bridge

  defp doc(content), do: %{"type" => "doc", "content" => content}

  defp paragraph(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}

  # What the adapter pushes: the document, and which of the server's documents
  # it was made on.
  defp change(kino, value, version \\ 0),
    do: push_event(kino, "change", %{"value" => value, "version" => version})

  # Kino.Test waits 100 ms for the first render, which a full suite running
  # beside Dialyzer has been seen to miss.
  defp connected(kino), do: connect(kino, nil, 2_000)

  defp subscribed(kino) do
    Kino.Control.subscribe(kino, :editor)
    kino
  end

  describe "new/1 and read/1" do
    test "start empty, as a fresh form field does" do
      assert Coelho.Kino.new() |> Coelho.Kino.read() == Coelho.empty(Schema.default())
    end

    test "read back the document they were given" do
      document = doc([paragraph("bonjour")])

      assert Coelho.Kino.new(value: document) |> Coelho.Kino.read() == document
    end

    test "refuse a value the schema does not accept, naming why" do
      assert_raise ArgumentError, ~r/not a document this schema accepts/, fn ->
        Coelho.Kino.new(value: doc([%{"type" => "script"}]))
      end
    end
  end

  describe "connecting" do
    test "renders the editor a LiveView would, holding the document" do
      kino = Coelho.Kino.new(value: doc([paragraph("bonjour")]), placeholder: "Write")
      %{html: html} = connected(kino)

      assert html =~ ~s(phx-hook="Coelho")
      assert html =~ "data-coelho-schema"
      assert html =~ "bonjour"
      assert html =~ "Write"
      refute html =~ "data-coelho-upload="
    end

    test "renders under the schema it was given" do
      schema = Schema.restrict(Schema.default(), nodes: [:doc, :paragraph, :text], marks: [:bold])
      %{html: html} = schema |> then(&Coelho.Kino.new(schema: &1)) |> connected()

      refute html =~ "heading"
      refute html =~ "italic"
    end
  end

  describe "a change from the browser" do
    test "is kept and announced when the schema accepts it" do
      kino = Coelho.Kino.new() |> subscribed()
      document = doc([paragraph("tapé")])

      change(kino, JSON.encode!(document))

      assert_receive {:editor, %{type: :change, document: ^document}}
      assert Coelho.Kino.read(kino) == document
    end

    test "is not announced twice when nothing changed" do
      document = doc([paragraph("même")])
      kino = Coelho.Kino.new(value: document) |> subscribed()

      change(kino, JSON.encode!(document))

      refute_receive {:editor, _event}
    end

    # The claim the whole library rests on: what the browser sends is input.
    test "is refused, and the editor put back, when the schema does not accept it" do
      kept = doc([paragraph("gardé")])
      kino = Coelho.Kino.new(value: kept) |> subscribed()
      sent_back = %{value: JSON.encode!(kept), version: 0}

      # Only a connected client can be sent the document back, as in Livebook.
      connected(kino)

      hostile =
        doc([
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "text",
                "text" => "click",
                "marks" => [%{"type" => "link", "attrs" => %{"href" => "javascript:alert(1)"}}]
              }
            ]
          }
        ])

      for sent <- [JSON.encode!(hostile), "not json", JSON.encode!(%{"type" => "script"})] do
        change(kino, sent)

        assert_send_event(kino, "set", ^sent_back)
        refute_receive {:editor, _event}
        assert Coelho.Kino.read(kino) == kept
      end
    end

    test "ignores a payload that is not a document string" do
      kino = Coelho.Kino.new() |> subscribed()

      push_event(kino, "change", JSON.encode!(doc([paragraph("no envelope")])))
      push_event(kino, "change", %{"value" => %{"type" => "doc"}, "version" => 0})
      push_event(kino, "unknown", "x")

      refute_receive {:editor, _event}
      assert Coelho.Kino.read(kino) == Coelho.empty(Schema.default())
    end

    test "hands what the hook asks of a LiveView on to listeners" do
      kino = Coelho.Kino.new() |> subscribed()

      push_event(kino, "hook", %{"event" => "mention", "payload" => %{"query" => "ad"}})

      assert_receive {:editor, %{type: :hook, event: "mention", payload: %{"query" => "ad"}}}
    end
  end

  describe "set/2" do
    test "replaces the document in every editor and announces it" do
      kino = Coelho.Kino.new() |> subscribed()
      document = doc([paragraph("depuis Elixir")])
      sent = %{value: JSON.encode!(document), version: 1}

      assert Coelho.Kino.set(kino, document) == :ok

      assert_broadcast_event(kino, "set", ^sent)
      assert_receive {:editor, %{type: :change, document: ^document}}
      assert Coelho.Kino.read(kino) == document
      assert %{html: html} = connected(kino)
      assert html =~ "depuis Elixir"
    end

    # A keystroke still in flight when set/2 replaced the document was made on
    # the old one; taken, it would undo the replacement here while the editor
    # shows it.
    test "is not undone by a change made on the document it replaced" do
      kino = Coelho.Kino.new() |> subscribed()
      document = doc([paragraph("depuis Elixir")])

      assert Coelho.Kino.set(kino, document) == :ok
      assert_receive {:editor, %{type: :change}}

      change(kino, JSON.encode!(doc([paragraph("tapé avant")])), 0)
      refute_receive {:editor, _event}
      assert Coelho.Kino.read(kino) == document

      typed = doc([paragraph("tapé après")])
      change(kino, JSON.encode!(typed), 1)
      assert_receive {:editor, %{type: :change, document: ^typed}}
    end

    test "connects an editor at the version it carries" do
      kino = Coelho.Kino.new()
      assert %{version: 0} = connected(kino)

      Coelho.Kino.set(kino, doc([paragraph("un")]))
      assert %{version: 1} = connected(kino)
    end

    test "leaves the editor alone and says why when the schema refuses" do
      kept = doc([paragraph("gardé")])
      kino = Coelho.Kino.new(value: kept)

      assert {:error, [%Coelho.Document.Error{} | _]} =
               Coelho.Kino.set(kino, doc([%{"type" => "script"}]))

      assert Coelho.Kino.read(kino) == kept
    end
  end
end
