defmodule Coelho.EditorTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Coelho.Schema

  defp form(value), do: to_form(%{"body" => value}, as: :post)

  defp render(assigns) do
    render_component(&Coelho.LiveView.coelho_editor/1, assigns)
  end

  describe "coelho_editor/1" do
    test "renders the document as JSON in a hidden input named after the field" do
      document = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hello"}]}
        ]
      }

      html = render(%{field: form(document)[:body]})

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(name="post[body]")
      assert html =~ "hello"
    end

    test "a rejected document comes back as the text that was posted" do
      # phoenix_ecto hands back the raw parameter when a cast fails, so the
      # writer does not lose their work. Encoding that again would put a JSON
      # string where the hook expects a document.
      posted = ~s({"type":"doc","content":[{"type":"script"}]})

      html = render(%{field: form(posted)[:body]})

      assert html =~ "&quot;script&quot;"
      refute html =~ ~s(value="&quot;{)
    end

    test "seeds an empty document when the field has no value" do
      html = render(%{field: form(nil)[:body]})

      assert html =~ "&quot;type&quot;:&quot;doc&quot;"
      assert html =~ "paragraph"
    end

    test "the editor's id is the one insert_node has to name" do
      field = form(nil)[:body]
      html = render(%{field: field})

      assert html =~ ~s(id="#{Coelho.LiveView.editor_id(field)}")
    end

    test "the toolbar is the hook's too, so its state survives a render" do
      html = render(%{field: form(nil)[:body]})

      # Two ignored regions: the editor's DOM, and the toolbar whose
      # aria-pressed the hook keeps in step with the cursor.
      assert html |> String.split(~s(phx-update="ignore")) |> length() == 3
      assert html =~ ~r/id="post_body-editor-toolbar-[a-z0-9]+"/
    end

    test "hands ProseMirror its own subtree, and only that" do
      html = render(%{field: form(nil)[:body]})

      assert html =~ ~s(phx-hook="Coelho")
      # The editor's DOM is the browser's; LiveView patching it would fight
      # ProseMirror on every keystroke.
      assert html =~ ~s(phx-update="ignore")
    end

    test "exports the schema the server validates against" do
      html = render(%{field: form(nil)[:body]})

      assert [_, encoded] = Regex.run(~r/data-coelho-schema="([^"]*)"/, html)

      exported =
        encoded
        |> String.replace("&quot;", "\"")
        |> String.replace("&#39;", "'")
        |> String.replace("&amp;", "&")
        |> JSON.decode!()

      assert exported == JSON.decode!(JSON.encode!(Schema.to_json(Schema.default())))
    end

    test "renders the requested toolbar commands, in order" do
      html = render(%{field: form(nil)[:body], toolbar: ~w(bold link)})

      assert [_, "bold"] = Regex.run(~r/data-coelho-command="([^"]*)"/, html)
      assert html =~ ~s(data-coelho-command="link")
      refute html =~ ~s(data-coelho-command="italic")
    end

    test "the placeholder is rendered by the server, for CSS to pick up" do
      html = render(%{field: form(nil)[:body], placeholder: "Write something"})

      # Not set by the hook: phx-update="ignore" spares an element's children,
      # not its own attributes, so LiveView would undo that on the next patch.
      assert html =~ ~s(data-placeholder="Write something")
    end

    test "an empty toolbar list hides the toolbar entirely" do
      html = render(%{field: form(nil)[:body], toolbar: []})

      refute html =~ "coelho-toolbar"
    end

    test "a custom schema is the one exported" do
      schema =
        Schema.new(nodes: [doc: [content: "line+"], line: [content: "inline*", group: "block"]])

      html = render(%{field: form(nil)[:body], document_schema: schema})

      assert html =~ "&quot;line&quot;"
      refute html =~ "&quot;blockquote&quot;"
    end

    test "drops toolbar commands the schema does not declare" do
      schema =
        Schema.new(nodes: [doc: [content: "line+"], line: [content: "inline*", group: "block"]])

      html =
        render(%{
          field: form(nil)[:body],
          document_schema: schema,
          toolbar: ~w(bold blockquote undo)
        })

      # A button for a node or mark the schema never declared would do
      # nothing at all when clicked.
      refute html =~ ~s(data-coelho-command="bold")
      refute html =~ ~s(data-coelho-command="blockquote")
      assert html =~ ~s(data-coelho-command="undo")
    end
  end

  describe "attachments" do
    test "an upload config enables dropping and pasting files" do
      upload = struct!(Phoenix.LiveView.UploadConfig, name: :attachment, ref: "0")

      html = render(%{field: form(nil)[:body], upload: upload})

      assert html =~ ~s(data-coelho-upload="attachment")
    end

    test "no upload config means no file input at all" do
      html = render(%{field: form(nil)[:body]})

      refute html =~ "data-coelho-upload"
      refute html =~ "coelho-file-input"
    end
  end
end
