if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Coelho.LiveView do
    @moduledoc """
    The editor, as a function component.

        <.coelho_editor field={@form[:body]} />

    ## What the component actually does

    It renders three things: a toolbar, an empty container, and a hidden
    input carrying the document as JSON. The container is the editor's, and
    it is marked `phx-update="ignore"` — ProseMirror owns that subtree and
    LiveView must never patch it. Everything the server needs to know
    travels through the hidden input, so the editor is an ordinary form
    field: `Ecto.Changeset.cast/3` sees it, `phx-change` sees it, and no
    special server side event is involved.

    The schema is serialised into a `data-` attribute, so the browser builds
    its ProseMirror schema from the same declaration that validates the
    document server side.

    ## Attachments

    Pass an upload config and the editor accepts dropped and pasted files,
    handing them to LiveView's own upload channel. The application consumes
    them, stores the bytes wherever it likes, and pushes back the node to
    insert:

        <.coelho_editor field={@form[:body]} upload={@uploads.attachment} />

        def handle_progress(:attachment, entry, socket) when entry.done? do
          attachment = consume_uploaded_entry(socket, entry, &MyApp.Uploads.store/1)

          {:noreply,
           push_event(socket, "coelho:attachment", %{
             node: Coelho.Attachment.to_node(attachment),
             url: MyApp.Uploads.url(attachment.key)
           })}
        end

    The `url` in that payload is only the editor's preview. What gets stored
    in the document is the key; the URL is resolved again on every render.
    See `Coelho.Attachments`.

    ## Wiring the hook

    The JavaScript side ships with the package. In `assets/js/app.js`:

        import { Coelho } from "../../deps/coelho/assets/js/coelho.js"

        const liveSocket = new LiveSocket("/live", Socket, {
          hooks: { Coelho, ...otherHooks }
        })

    It expects `@nseaprotector/acme-script`, `prosemirror-state`,
    `prosemirror-view`, `prosemirror-model`, `prosemirror-keymap`,
    `prosemirror-commands` and `prosemirror-history` to be installed in the
    application.

    A schema of your own also needs its DOM mapping on the browser side, which
    `createCoelhoHook/1` takes:

        import { createCoelhoHook } from "../../deps/coelho/assets/js/coelho.js"

        const Coelho = createCoelhoHook({
          nodes: { mention: (node) => ["span", { class: "mention" }, "@" + node.attrs.user_id] }
        })

    """

    use Phoenix.Component

    alias Coelho.Schema

    @doc """
    Renders the rich text editor for a form field.
    """
    attr(:field, Phoenix.HTML.FormField, required: true)
    attr(:id, :string, default: nil, doc: "defaults to the field's own id, suffixed")

    attr(:document_schema, Schema,
      default: nil,
      doc: "the schema to edit against, `Coelho.Schema.default/0` when omitted"
    )

    attr(:toolbar, :list,
      default: ~w(bold italic strike code link heading bullet_list ordered_list blockquote),
      doc: "commands to show, in order; an empty list hides the toolbar"
    )

    attr(:upload, :any,
      default: nil,
      doc: "an `%Phoenix.LiveView.UploadConfig{}`; enables dropping and pasting files"
    )

    attr(:placeholder, :string, default: nil)
    attr(:class, :string, default: nil)
    attr(:rest, :global)

    def coelho_editor(assigns) do
      schema = assigns.document_schema || Schema.default()
      id = assigns.id || assigns.field.id <> "-editor"

      assigns =
        assigns
        |> assign(:id, id)
        |> assign(:schema_json, JSON.encode!(Schema.to_json(schema)))
        |> assign(:value_json, JSON.encode!(assigns.field.value || Coelho.empty(schema)))
        |> assign(:toolbar, Enum.filter(assigns.toolbar, &supported?(schema, &1)))

      ~H"""
      <div
        id={@id}
        class={["coelho", @class]}
        phx-hook="Coelho"
        data-coelho-schema={@schema_json}
        data-coelho-input={@field.id}
        data-coelho-placeholder={@placeholder}
        data-coelho-upload={@upload && @upload.name}
        {@rest}
      >
        <div :if={@toolbar != []} class="coelho-toolbar" role="toolbar">
          <button
            :for={command <- @toolbar}
            type="button"
            class="coelho-command"
            data-coelho-command={command}
            aria-label={command}
          >
            {command}
          </button>
        </div>
        <div id={@id <> "-content"} class="coelho-content" phx-update="ignore"></div>
        <.live_file_input :if={@upload} upload={@upload} class="coelho-file-input" />
        <input type="hidden" name={@field.name} id={@field.id} value={@value_json} />
      </div>
      """
    end

    # A button for a node the schema does not declare would do nothing when
    # clicked, so the toolbar is filtered against the schema rather than
    # trusting the caller to keep the two lists in step.
    @mark_commands ~w(bold italic strike code link)
    @always ~w(undo redo)

    defp supported?(_schema, command) when command in @always, do: true

    defp supported?(schema, command) when command in @mark_commands do
      match?({:ok, _}, Schema.resolve_mark_name(schema, command))
    end

    defp supported?(schema, command) do
      match?({:ok, _}, Schema.resolve_node_name(schema, command))
    end
  end
end
