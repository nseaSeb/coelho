defmodule Coelho.EditorOptionsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Coelho.{LiveView, Schema}

  defp render(assigns) do
    assigns = Map.merge(%{__changed__: nil}, assigns)

    LiveView.coelho_editor(assigns) |> rendered_to_string()
  end

  defp defaults(assigns) do
    Map.merge(
      %{
        field: nil,
        name: nil,
        value: nil,
        id: nil,
        document_schema: nil,
        schema_id: nil,
        toolbar: ~w(bold link),
        labels: %{},
        maxlength: nil,
        flush_event: nil,
        flush_token: nil,
        upload: nil,
        placeholder: nil,
        class: nil,
        rest: %{}
      },
      assigns
    )
  end

  defp editor(assigns), do: assigns |> defaults() |> render()

  defp paragraph(text) do
    %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}
      ]
    }
  end

  describe "name and value, without a form field" do
    test "renders the hidden input the surface actually posts" do
      html = editor(%{name: "page[intro_doc]", value: paragraph("bonjour")})

      assert html =~ ~s(name="page[intro_doc]")
      assert html =~ ~s(id="page_intro_doc")
      assert html =~ ~s(data-coelho-input="page_intro_doc")
      assert html =~ "bonjour"
    end

    test "derives the editor id the same way a form would" do
      assert editor(%{name: "page[intro_doc]"}) =~ ~s(id="page_intro_doc-editor")
      assert LiveView.editor_id("page[intro_doc]") == "page_intro_doc-editor"
    end

    test "seeds an empty document when there is no value" do
      html = editor(%{name: "cgv[text]"})

      assert html =~ ~s(name="cgv[text]")
      assert html =~ "paragraph"
    end

    test "says what is missing when neither is given" do
      assert_raise ArgumentError, ~r/either a :field, or a :name and a :value/, fn ->
        editor(%{})
      end
    end
  end

  describe "the character counter" do
    test "is absent unless asked for" do
      refute editor(%{name: "a[b]"}) =~ "coelho-counter"
    end

    test "is right at the first paint, before the hook has started" do
      html = editor(%{name: "a[b]", value: paragraph("douze lettres"), maxlength: 20})

      assert html =~ ~s(data-coelho-maxlength="20")
      assert html =~ ~s(<span data-coelho-count aria-live="polite">13</span>)
    end

    test "counts what was typed, from the raw JSON a rejected document comes back as" do
      html = editor(%{name: "a[b]", value: JSON.encode!(paragraph("abc")), maxlength: 20})

      assert html =~ ~s(<span data-coelho-count aria-live="polite">3</span>)
    end

    test "lives inside an ignored subtree, so a render cannot put the first number back" do
      html = editor(%{name: "a[b]", maxlength: 20})

      assert html =~ ~r/id="[^"]*-counter" class="coelho-counter" phx-update="ignore"/
    end
  end

  describe "the flush" do
    test "carries the event and the application's own token" do
      html = editor(%{name: "a[b]", flush_event: "flush", flush_token: 7})

      assert html =~ ~s(data-coelho-flush-event="flush")
      assert html =~ ~s(data-coelho-flush-token="7")
    end

    test "is absent unless asked for" do
      html = editor(%{name: "a[b]"})

      refute html =~ "data-coelho-flush-event"
      refute html =~ "data-coelho-flush-token"
    end
  end

  describe "toolbar labels" do
    test "default to the command name" do
      assert editor(%{name: "a[b]", toolbar: ~w(bold)}) =~ ~s(aria-label="bold")
    end

    test "are the application's when it has a translator" do
      html = editor(%{name: "a[b]", toolbar: ~w(bold link), labels: %{"bold" => "Gras"}})

      assert html =~ ~s(aria-label="Gras")
      assert html =~ "Gras"
      # Untranslated commands keep their name rather than disappearing.
      assert html =~ ~s(aria-label="link")
    end
  end

  describe "the shared schema" do
    defp shared(schema) do
      %{__changed__: nil, id: "page-schema", document_schema: schema}
      |> LiveView.coelho_schema()
      |> rendered_to_string()
    end

    test "one element, and editors that point at it" do
      html = shared(nil)

      assert html =~ ~s(<div id="page-schema" hidden data-coelho-schema=)
      assert html =~ "&quot;topNode&quot;:&quot;doc&quot;"

      editor = editor(%{name: "a[b]", schema_id: "page-schema"})

      assert editor =~ ~s(data-coelho-schema-src="page-schema")
      refute editor =~ "data-coelho-schema="
    end

    test "is patched like anything else, so a schema change reaches it" do
      # `phx-update="ignore"` here would freeze the one thing the editors read
      # to notice the schema moved: the rebuild would run and re-read the old
      # JSON, masking the change for good.
      refute shared(nil) =~ "phx-update"
    end

    test "carries the schema's own fingerprint, for the editor to check against" do
      assert check(shared(nil)) == check(editor(%{name: "a[b]"}))
    end

    test "and a different schema gives a different one, which is the mismatch" do
      narrowed = Schema.restrict(Schema.default(), marks: [:bold])

      refute check(shared(narrowed)) == check(editor(%{name: "a[b]"}))
    end

    test "the check is the schema alone, so the toolbar does not disturb it" do
      one = editor(%{name: "a[b]", toolbar: ~w(bold)})
      other = editor(%{name: "a[b]", toolbar: ~w(bold link)})

      assert check(one) == check(other)
      refute version(one) == version(other)
    end
  end

  defp check(html) do
    [_match, check] = Regex.run(~r/data-coelho-schema-check="([^"]+)"/, html)
    check
  end

  describe "the schema fingerprint" do
    test "changes when the schema does, so the hook can follow" do
      one = editor(%{name: "a[b]"})

      other =
        editor(%{
          name: "a[b]",
          document_schema: Schema.restrict(Schema.default(), marks: [:bold])
        })

      assert version(one) != version(other)
    end

    test "changes when the toolbar does, so its buttons are redrawn" do
      assert version(editor(%{name: "a[b]", toolbar: ~w(bold)})) !=
               version(editor(%{name: "a[b]", toolbar: ~w(bold link)}))
    end

    test "is the toolbar container's id, which is what makes LiveView replace it" do
      html = editor(%{name: "a[b]"})

      assert html =~ ~s(id="a_b-editor-toolbar-#{version(html)}")
    end
  end

  defp version(html) do
    [_match, version] = Regex.run(~r/data-coelho-schema-version="([^"]+)"/, html)
    version
  end
end
