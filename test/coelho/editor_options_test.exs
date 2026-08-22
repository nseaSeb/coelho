defmodule Coelho.EditorOptionsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

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
        icons: %{},
        field_labels: %{},
        maxlength: nil,
        debounce: nil,
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

  describe "the debounce" do
    test "is rendered on the input the document travels in" do
      # LiveView reads `phx-debounce` off the element that emits the event and
      # walks no ancestors, so the root and the enclosing form are both out of
      # reach: this attribute is the only way an application can space out the
      # round trip a long document makes on every keystroke.
      html = editor(%{name: "post[body]", value: paragraph("x"), debounce: 300})

      assert html =~ ~r/<input[^>]*type="hidden"[^>]*phx-debounce="300"/ or
               html =~ ~r/<input[^>]*phx-debounce="300"[^>]*type="hidden"/
    end

    test "is milliseconds and nothing else" do
      # LiveView's `"blur"` waits for a blur event on the element carrying the
      # attribute, and a hidden input never blurs — the change would be held
      # for the life of the page. The attribute is typed so that saying it is
      # a mistake made at the call site rather than a page that goes quiet.
      assert_raise ArgumentError, ~r/debounce/, fn ->
        render_component(&LiveView.coelho_editor/1, %{
          name: "post[body]",
          value: paragraph("x"),
          debounce: "blur"
        })
      end
    end

    test "is absent when nothing asked for one" do
      html = editor(%{name: "post[body]", value: paragraph("x")})

      refute html =~ "phx-debounce"
    end
  end

  describe "a heading that names its level" do
    test "is a button of its own, saying which level it makes" do
      html = editor(%{name: "post[body]", value: paragraph("x"), toolbar: ~w(heading heading_3)})

      assert html =~ ~s(data-coelho-command="heading_3")
      assert html =~ ~s(aria-label="Heading 3")
      assert html =~ ~s(data-coelho-command="heading")
    end

    test "takes its own label" do
      html =
        editor(%{
          name: "post[body]",
          value: paragraph("x"),
          toolbar: ~w(heading_3),
          labels: %{"heading_3" => "Sous-titre"}
        })

      assert html =~ ~s(aria-label="Sous-titre")
    end

    test "is dropped when the schema's own level refuses it" do
      # Filtered by the attribute's validator, like an alignment: a schema
      # allowing two levels shows two buttons, not six.
      narrowed =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [content: "text*", group: "block", render: {"p", []}],
            heading: [
              content: "text*",
              group: "block",
              attrs: [level: [default: 1, validate: {:one_of, [1, 2]}]],
              render: {"h2", []}
            ]
          ]
        )

      html =
        editor(%{
          name: "post[body]",
          value: paragraph("x"),
          document_schema: narrowed,
          toolbar: ~w(heading_2 heading_3)
        })

      assert html =~ ~s(data-coelho-command="heading_2")
      refute html =~ ~s(data-coelho-command="heading_3")
    end

    test "is dropped by a schema with no heading at all" do
      plain =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [content: "text*", group: "block", render: {"p", []}]
          ]
        )

      html =
        editor(%{
          name: "post[body]",
          value: paragraph("x"),
          document_schema: plain,
          toolbar: ~w(heading_2)
        })

      refute html =~ "data-coelho-command=\"heading"
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
    test "default to English, and are the tooltip as well as the name" do
      # A button showing an icon says nothing on its own. The label is what
      # both a pointer and a screen reader are told, so they say the same
      # thing — and `bullet_list` would be worse than saying nothing.
      html = editor(%{name: "a[b]", toolbar: ~w(bold bullet_list)})

      assert html =~ ~s(title="Bold")
      assert html =~ ~s(aria-label="Bold")
      assert html =~ ~s(title="Bulleted list")
    end

    test "are the application's when it has a translator" do
      html = editor(%{name: "a[b]", toolbar: ~w(bold link), labels: %{"bold" => "Gras"}})

      assert html =~ ~s(aria-label="Gras")
      assert html =~ ~s(title="Gras")
      # Untranslated commands keep their English rather than disappearing.
      assert html =~ ~s(aria-label="Link")
    end

    test "an icon of the application's replaces the one the library draws" do
      html =
        editor(%{
          name: "a[b]",
          toolbar: ~w(bold italic),
          icons: %{"bold" => {:safe, ~s(<svg class="mine"></svg>)}}
        })

      assert html =~ ~s(<svg class="mine">)
      # And only that one: the rest keep theirs.
      assert html =~ ~s(<svg class="coelho-icon")
    end

    test "changing a drawing redraws the toolbar, though the commands did not move" do
      # The toolbar's id is its fingerprint, and the toolbar is a subtree
      # LiveView is told to ignore — so a fingerprint over the command names
      # alone would leave an editor showing the icon it was born with.
      one =
        editor(%{name: "a[b]", toolbar: ~w(bold), icons: %{"bold" => {:safe, "<svg id='a'/>"}}})

      two =
        editor(%{name: "a[b]", toolbar: ~w(bold), icons: %{"bold" => {:safe, "<svg id='b'/>"}}})

      assert toolbar_version(one) != toolbar_version(two)
    end

    test "name a command the library never heard of after itself" do
      schema =
        Coelho.Schema.extend(Coelho.Schema.default(),
          marks: [highlight: [render: {"mark", []}, parse: ["mark"]]]
        )

      html =
        editor(%{
          name: "a[b]",
          document_schema: schema,
          toolbar: ~w(highlight)
        })

      assert html =~ ~s(title="highlight")
      # And with no icon to draw, it shows the label rather than nothing.
      assert html =~ ~r{aria-label="highlight">\s*highlight\s*</button>}
      refute html =~ "coelho-icon"
    end
  end

  describe "what the field says" do
    test "is nothing at all until the application says something" do
      refute editor(%{name: "a[b]"}) =~ "data-coelho-field-labels"
    end

    test "travels as one attribute rather than six" do
      html =
        editor(%{
          name: "a[b]",
          field_labels: %{
            "link_label" => "Adresse du lien",
            "link_hint" => "Videz le champ pour retirer le lien."
          }
        })

      assert html =~ "data-coelho-field-labels="
      assert html =~ "Adresse du lien"
      assert html =~ "Videz le champ pour retirer le lien."
    end

    test "renders the place the hint goes, empty and hidden" do
      html = editor(%{name: "a[b]", toolbar: ~w(link)})

      # With an id, so the input can point aria-describedby at it while the
      # hint is shown — drawn is not said.
      assert html =~
               ~r/<span id="[^"]*-hint" class="coelho-link-hint" data-coelho-link-hint hidden>/
    end

    test "changing it redraws the toolbar, so a language switch reaches the field" do
      english = editor(%{name: "a[b]", field_labels: %{"link_label" => "Link address"}})
      french = editor(%{name: "a[b]", field_labels: %{"link_label" => "Adresse du lien"}})

      assert toolbar_version(english) != toolbar_version(french)
      # And not the schema's, which would rebuild the editor and cost the
      # writer their undo history over a word.
      assert version(english) == version(french)
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
      refute toolbar_version(one) == toolbar_version(other)
    end
  end

  defp check(html) do
    [_match, check] = Regex.run(~r/data-coelho-schema-version="([^"]+)"/, html)
    check
  end

  defp toolbar_version(html) do
    [_match, version] = Regex.run(~r/data-coelho-toolbar-version="([^"]+)"/, html)
    version
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

    test "the toolbar's own fingerprint moves with the commands" do
      assert toolbar_version(editor(%{name: "a[b]", toolbar: ~w(bold)})) !=
               toolbar_version(editor(%{name: "a[b]", toolbar: ~w(bold link)}))
    end

    test "and with their labels, which is a language switched mid-session" do
      english = editor(%{name: "a[b]", toolbar: ~w(bold), labels: %{"bold" => "Bold"}})
      french = editor(%{name: "a[b]", toolbar: ~w(bold), labels: %{"bold" => "Gras"}})

      assert toolbar_version(english) != toolbar_version(french)
      assert english =~ ~s(id="a_b-editor-toolbar-#{toolbar_version(english)}")
      assert french =~ ~s(id="a_b-editor-toolbar-#{toolbar_version(french)}")
    end

    test "but the schema's does not, so new words cost no undo history" do
      # The schema fingerprint is what makes the hook rebuild the editor,
      # which re-parses the document and starts a fresh history. Changing a
      # label must not reach for that.
      english = editor(%{name: "a[b]", toolbar: ~w(bold), labels: %{"bold" => "Bold"}})
      french = editor(%{name: "a[b]", toolbar: ~w(bold), labels: %{"bold" => "Gras"}})

      assert version(english) == version(french)

      assert version(editor(%{name: "a[b]", toolbar: ~w(bold)})) ==
               version(editor(%{name: "a[b]", toolbar: ~w(bold link)}))
    end

    test "the toolbar's is its container's id, which is what makes LiveView replace it" do
      html = editor(%{name: "a[b]"})

      assert html =~ ~s(id="a_b-editor-toolbar-#{toolbar_version(html)}")
    end
  end

  defp version(html) do
    [_match, version] = Regex.run(~r/data-coelho-schema-version="([^"]+)"/, html)
    version
  end
end
