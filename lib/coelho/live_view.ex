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

    ## Styling

    The component ships no styles. It gives CSS two things to work with: the
    root carries `coelho-empty` while the document has no text, and the
    content element carries `data-placeholder` — rendered by the server, not
    set by the hook, because `phx-update="ignore"` stops LiveView patching an
    element's children but not its own attributes, so anything JavaScript
    writes there is undone on the next patch. An empty editor shows its
    placeholder with

        .coelho-empty .coelho-content::before { content: attr(data-placeholder); }

    A placeholder node would have to be a node, and would end up validated,
    stored and rendered; this stays out of the document entirely.

    ## Attachments

    Pass an upload config and the editor accepts dropped and pasted files,
    handing them to LiveView's own upload channel. The application consumes
    them, stores the bytes wherever it likes, and pushes back the node to
    insert:

        <.coelho_editor field={@form[:body]} upload={@uploads.attachment} />

        def handle_progress(:attachment, entry, socket) when entry.done? do
          attachment = consume_uploaded_entry(socket, entry, &MyApp.Uploads.store/1)

          {:noreply,
           insert_node(socket, Coelho.Attachment.to_node(attachment),
             preview: MyApp.Uploads.url(attachment.key)
           )}
        end

    The preview is for the editor's eyes only. What gets stored in the
    document is the key; the URL is resolved again on every render. See
    `Coelho.Attachments`.

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
    Inserts a node at the editor's selection.

    The way anything the server decides on reaches the document: an
    attachment it has just stored, a mention it has just resolved, an embed
    it has just fetched. The node is built server side, against the same
    schema that will validate it on the way back.

        socket
        |> Coelho.LiveView.insert_node(Coelho.Attachment.to_node(attachment),
             preview: MyApp.Uploads.url(attachment.key))

    `:preview` is for the editor's eyes only — an attachment's URL, which the
    document does not carry and the renderer resolves again on every render.
    """
    @spec insert_node(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
            Phoenix.LiveView.Socket.t()
    def insert_node(socket, node, opts \\ []) when is_map(node) do
      Phoenix.LiveView.push_event(socket, "coelho:insert", %{
        node: node,
        preview: Keyword.get(opts, :preview)
      })
    end

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
        |> assign(:value_json, value_json(assigns.field.value, schema))
        |> assign(:toolbar, Enum.filter(assigns.toolbar, &supported?(schema, &1)))

      ~H"""
      <div
        id={@id}
        class={["coelho", @class]}
        phx-hook="Coelho"
        data-coelho-schema={@schema_json}
        data-coelho-input={@field.id}
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
        <div
          id={@id <> "-content"}
          class="coelho-content"
          data-placeholder={@placeholder}
          phx-update="ignore"
        ></div>
        <.live_file_input :if={@upload} upload={@upload} class="coelho-file-input" />
        <input type="hidden" name={@field.name} id={@field.id} value={@value_json} />
      </div>
      """
    end

    # When a document fails to cast, the form hands back the raw parameter —
    # the JSON the editor posted — so the writer does not lose what they were
    # working on. Encoding that again would put a JSON *string* in the input,
    # and the hook would be handed a string where a document belongs.
    defp value_json(nil, schema), do: JSON.encode!(Coelho.empty(schema))
    defp value_json(value, _schema) when is_binary(value), do: value
    defp value_json(value, _schema), do: JSON.encode!(value)

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
