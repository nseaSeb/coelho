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

    ## Captions

    A caption is an attribute of the node carrying it, not content inside it,
    so `caption` in the toolbar opens the same field on whichever node is
    selected and declares the attribute — an attachment, by default. The
    button is disabled the rest of the time.

    ## Links

    When the toolbar carries `link`, the component renders a field beside it
    rather than reaching for `window.prompt`, which blocks the page and
    ignores the application's design. The field opens on the selection, or on
    the whole link under the cursor when there is no selection; `Enter`
    confirms, `Escape` closes, and emptying it removes the link without
    touching the text.

    An application with its own link interface listens for the cancelable
    `coelho:link` event on the editor element and calls
    `event.detail.apply(href)` when it has an answer.

    ## Styling

    The toolbar carries `phx-update="ignore"` for the same reason the editor
    does: the hook keeps `aria-pressed` on each button in step with what is in
    force under the cursor, and LiveView would patch that away on the next
    render. The consequence is that the button list is fixed once rendered —
    changing `:toolbar` or the schema on a mounted editor will not redraw it.

    The component ships no styles. It gives CSS what it needs on the editor's
    own element, which ProseMirror creates inside the ignored container:
    `coelho-empty` while the document has no text, and `data-placeholder`,
    carried in from the container the server rendered it on. An empty editor
    shows its placeholder with

        .coelho-content .ProseMirror.coelho-empty::before {
          content: attr(data-placeholder);
        }

    Both live *inside* the ignored subtree on purpose: `phx-update="ignore"`
    stops LiveView patching an element's children, not its own attributes, so
    a class or attribute JavaScript writes on the root or on the container is
    undone by the next render.

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

    ## What stays the browser's

    Two things about a node cannot come from Elixir, because both are
    functions: how it *looks* (`toDOM`/`parseDOM`) and how it *behaves* — the
    drag handles on an image, a menu on an embed. `createCoelhoHook/1` takes
    the first as `nodes`/`marks` and the second as `nodeViews`, which is
    ProseMirror's own extension point, handed through untouched.

    Resizing an image is an example of the division. The *size* is a schema
    attribute like any other, added with `Coelho.Schema.extend/2`, validated
    and stored like any other; the *handles* that set it are a node view. And
    producing a smaller file — a thumbnail, a variant — is neither: the
    document stores a key, and what a key resolves to is the application's,
    so a resolver can answer with a variant it generated however it likes.
    Coelho never touches the bytes.

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
             id: editor_id(@form[:body]),
             preview: MyApp.Uploads.url(attachment.key))

    ## Options

      * `:id` — which editor to insert into, as `editor_id/1` returns it.
        `push_event/3` reaches the whole page, so **without this every editor
        on it inserts the node**, which is only ever right when there is one.
      * `:preview` — for the editor's eyes only: an attachment's URL, which
        the document does not carry and the renderer resolves again on every
        render.

    """
    @spec insert_node(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
            Phoenix.LiveView.Socket.t()
    def insert_node(socket, node, opts \\ []) when is_map(node) do
      Phoenix.LiveView.push_event(socket, "coelho:insert", %{
        node: node,
        id: Keyword.get(opts, :id),
        preview: Keyword.get(opts, :preview)
      })
    end

    @doc """
    The DOM id of the editor rendered for a form field.

    What `insert_node/3` needs to reach one editor rather than all of them.
    """
    @spec editor_id(Phoenix.HTML.FormField.t() | String.t()) :: String.t()
    def editor_id(%Phoenix.HTML.FormField{id: id}), do: id <> "-editor"
    def editor_id(name) when is_binary(name), do: input_id(name) <> "-editor"

    # The id a form gives an input, from the name alone — `page[intro_doc]`
    # becomes `page_intro_doc`. The editor needs one whether or not a
    # `%FormField{}` was there to supply it.
    defp input_id(name) do
      name |> String.replace("]", "") |> String.replace("[", "_")
    end

    @doc """
    Renders the schema once, for several editors to share.

    Each editor otherwise carries the whole exported schema in a `data-`
    attribute of its own — 1.3 KB for the schema that ships, which six
    editors on a page turn into eight. Render this once and point the
    editors at it:

        <.coelho_schema id="page-schema" document_schema={MyApp.RichText.schema()} />

        <.coelho_editor
          name="page[intro_doc]"
          value={@draft["intro_doc"]}
          document_schema={MyApp.RichText.schema()}
          schema_id="page-schema"
        />

    **Give the editors the same `:document_schema`.** `:schema_id` says where
    the exported JSON lives, not which schema it is: the editor still filters
    its toolbar and stamps its fingerprint from its own `:document_schema`,
    and an editor working from one schema while reading another is a mismatch
    that would show up as buttons quietly doing nothing. The fingerprints are
    compared in the browser, so the mismatch is an error and not a mystery.

    The saving is on the first render. LiveView omits an unchanged dynamic
    from a diff, so the repetition does not cost anything again on every
    patch — but it is still eight kilobytes of the page that opens.
    """
    attr(:id, :string, required: true)

    attr(:document_schema, Schema,
      default: nil,
      doc: "the schema to export, `Coelho.Schema.default/0` when omitted"
    )

    def coelho_schema(assigns) do
      schema = assigns.document_schema || Schema.default()

      assigns =
        assigns
        |> assign(:json, JSON.encode!(Schema.to_json(schema)))
        |> assign(:check, version(schema, nil))

      # An attribute and not a `<script>`. A script's content is raw text —
      # the parser decodes no entities inside it, so the JSON would have to be
      # escaped at the JSON level rather than the HTML level — and marking it
      # `phx-update="ignore"` to keep LiveView off it, which the first version
      # of this did, freezes the very thing the editors read to notice that
      # the schema moved. An attribute is patched like any other, and the
      # parser decodes it correctly.
      ~H"""
      <div id={@id} hidden data-coelho-schema={@json} data-coelho-schema-check={@check}></div>
      """
    end

    @doc """
    Renders the rich text editor.

    Give it a form field, or a name and a value:

        <.coelho_editor field={@form[:body]} />
        <.coelho_editor name="page[intro_doc]" value={@draft["intro_doc"]} />

    The second form is for a surface that has no changeset behind it — a
    JSONB draft whose keys are historical, a field posted straight into
    `phx-change` — where building a `%Phoenix.HTML.FormField{}` to satisfy
    the component would be building a fiction.

    ## Losing the last keystrokes, and how not to

    The editor writes into its hidden input and lets `phx-change` carry it,
    which means a `phx-debounce` can still be holding the last edit when the
    block leaves the DOM. Nothing arrives, and the writer loses what they
    typed last. Cancelling a draft, switching a tab, collapsing a section:
    each of those removes the editor, and each of those is where it bites.

    `:flush_event` closes it. The hook pushes the document on the way out:

        <.coelho_editor
          name="page[intro_doc]"
          value={@draft["intro_doc"]}
          flush_event="flush"
          flush_token={@generation}
        />

        def handle_event("flush", %{"token" => token, "name" => name, "document" => document}, socket) do
          if token == to_string(socket.assigns.generation) do
            {:noreply, put_draft(socket, name, document)}
          else
            {:noreply, socket}
          end
        end

    **The token comes back as a string.** It travels as a DOM attribute, so
    whatever it was rendered from arrives as text: comparing it to an integer
    generation is always false, and every flush is dropped by the clause that
    was meant to catch the stale ones — the data loss `:flush_event` exists
    to prevent, failing silently.

    The token is yours and the comparison is yours, because only the
    application knows what a generation is. It matters: cancelling a draft
    re-renders the editors, and the editors being torn down flush *the
    content from before the cancellation*. Without a token that the
    application bumps when it cancels, the flush puts back exactly what was
    just thrown away.

    ## Counting characters

    `:maxlength` renders a counter beside the toolbar and keeps it in step.
    The count is `Coelho.Document.text_length/1` — the text nodes
    concatenated, which is what the writer typed — and the server renders the
    first one, so an existing document does not read zero until the hook has
    started.

    The attribute does not stop anyone typing. What it does is show the
    number and mark the counter with `coelho-over` past the limit; refusing
    the document is the schema's job, through `limits: [max_text_length: …]`,
    and doing it in two places would let the two disagree.

    ## Following a schema change

    The container carries `phx-update="ignore"`, so LiveView never patches
    what ProseMirror owns — which used to mean that **a schema changed on a
    mounted editor was not picked up**: the classes, the marks and the node
    types stayed the ones read at mount, and what the writer saw stopped
    matching what the page would render.

    The hook now watches an exported-schema fingerprint on its own element
    and rebuilds the view when it moves, keeping the document. The toolbar is
    redrawn with it. Ids are untouched, so `editor_id/1` and `insert_node/3`
    go on working.
    """
    attr(:field, Phoenix.HTML.FormField,
      default: nil,
      doc: "a form field; give this or `:name` and `:value`"
    )

    attr(:name, :string, default: nil, doc: "the hidden input's name, without a form field")
    attr(:value, :any, default: nil, doc: "the document, without a form field")
    attr(:id, :string, default: nil, doc: "defaults to the field's own id, suffixed")

    attr(:document_schema, Schema,
      default: nil,
      doc: "the schema to edit against, `Coelho.Schema.default/0` when omitted"
    )

    attr(:schema_id, :string,
      default: nil,
      doc: "id of a `coelho_schema/1` to read the schema from, instead of carrying it"
    )

    attr(:toolbar, :list,
      default:
        ~w(bold italic strike code link heading bullet_list ordered_list blockquote caption),
      doc: "commands to show, in order; an empty list hides the toolbar"
    )

    attr(:labels, :map,
      default: %{},
      doc: "command to label, for a toolbar that has to speak the reader's language"
    )

    attr(:maxlength, :integer, default: nil, doc: "shows a character counter; does not enforce")

    attr(:flush_event, :string,
      default: nil,
      doc: "event pushed with the document when the editor leaves the DOM"
    )

    attr(:flush_token, :any,
      default: nil,
      doc:
        "sent back with `:flush_event`, for the application to refuse a stale flush. " <>
          "It travels as a DOM attribute, so it arrives back as a string"
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
      {name, value, input_id} = input_for!(assigns)
      toolbar = Enum.filter(assigns.toolbar, &supported?(schema, &1))

      assigns =
        assigns
        |> assign(:id, assigns.id || editor_id(assigns.field || name))
        |> assign(:input_name, name)
        |> assign(:input_id, input_id)
        |> assign(:schema_json, assigns.schema_id || JSON.encode!(Schema.to_json(schema)))
        |> assign(:version, version(schema, toolbar))
        |> assign(:check, version(schema, nil))
        |> assign(:value_json, value_json(value, schema))
        |> assign(:count, initial_count(value))
        |> assign(:toolbar, toolbar)

      ~H"""
      <div
        id={@id}
        class={["coelho", @class]}
        phx-hook="Coelho"
        data-coelho-schema={is_nil(@schema_id) && @schema_json}
        data-coelho-schema-src={@schema_id}
        data-coelho-schema-version={@version}
        data-coelho-schema-check={@check}
        data-coelho-input={@input_id}
        data-coelho-upload={@upload && @upload.name}
        data-coelho-maxlength={@maxlength}
        data-coelho-flush-event={@flush_event}
        data-coelho-flush-token={@flush_token && to_string(@flush_token)}
        {@rest}
      >
        <div
          :if={@toolbar != []}
          id={@id <> "-toolbar-" <> @version}
          class="coelho-toolbar"
          role="toolbar"
          phx-update="ignore"
        >
          <button
            :for={command <- @toolbar}
            type="button"
            class="coelho-command"
            data-coelho-command={command}
            aria-label={Map.get(@labels, command, command)}
          >
            {Map.get(@labels, command, command)}
          </button>

          <span
            :if={"link" in @toolbar or "caption" in @toolbar}
            class="coelho-link"
            data-coelho-link-zone
            hidden
          >
            <%!-- The type, the placeholder and the label are set by the hook:
                  the field serves links and captions, and asking for a URL
                  when it wants a caption marks a good one as invalid. --%>
            <input type="text" class="coelho-link-input" data-coelho-link-input />
          </span>
        </div>
        <%!-- The count is written by the hook, so it lives inside an ignored
              subtree: LiveView patches an element's attributes and text even
              when it spares an ignored element's children, and the next
              render would put the server's first number back. --%>
        <span :if={@maxlength} id={@id <> "-counter"} class="coelho-counter" phx-update="ignore">
          <span data-coelho-count aria-live="polite">{@count}</span>
          <span class="coelho-counter-max">{@maxlength}</span>
        </span>
        <div
          id={@id <> "-content"}
          class="coelho-content"
          data-placeholder={@placeholder}
          phx-update="ignore"
        ></div>
        <.live_file_input :if={@upload} upload={@upload} class="coelho-file-input" />
        <input type="hidden" name={@input_name} id={@input_id} value={@value_json} />
      </div>
      """
    end

    # A form field carries its own name, value and id. Without one they have
    # to be given, and the id is derived the way a form would derive it.
    defp input_for!(%{field: %Phoenix.HTML.FormField{} = field}),
      do: {field.name, field.value, field.id}

    defp input_for!(%{name: name} = assigns) when is_binary(name),
      do: {name, assigns.value, input_id(name)}

    defp input_for!(_assigns) do
      raise ArgumentError,
            "coelho_editor needs either a :field, or a :name and a :value — " <>
              ~s(for example name="page[intro_doc]" value={@draft["intro_doc"]})
    end

    # What the browser has to notice a change in: the schema it builds from,
    # and the buttons drawn against it. Both sit inside `phx-update="ignore"`
    # subtrees that LiveView will not touch, so the hook is told rather than
    # left to find out.
    #
    # Two fingerprints, because they answer two questions. The editor's
    # `-version` covers the schema *and* its toolbar, and moving it is what
    # makes the hook rebuild and LiveView redraw the buttons. The `-check`
    # covers the schema alone, and is the one a shared `coelho_schema/1` can
    # be compared against — its own toolbar does not exist.
    defp version(schema, toolbar) do
      {Schema.to_json(schema), toolbar}
      |> :erlang.phash2()
      |> Integer.to_string(36)
      |> String.downcase()
    end

    # The counter has to be right at the first paint. Rendered empty and left
    # to the hook, it reads zero on an existing document until the JavaScript
    # has started — which on a slow first load is long enough to be seen and
    # believed.
    defp initial_count(value) when is_map(value), do: Coelho.Document.text_length(value)

    defp initial_count(value) when is_binary(value) do
      case JSON.decode(value) do
        {:ok, document} -> Coelho.Document.text_length(document)
        {:error, _reason} -> 0
      end
    end

    defp initial_count(_value), do: 0

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
    # `caption` acts on whichever selected node declares the attribute, so it
    # cannot be looked up as a node or a mark of its own.
    @always ~w(undo redo caption)

    defp supported?(_schema, command) when command in @always, do: true

    defp supported?(schema, command) when command in @mark_commands do
      match?({:ok, _}, Schema.resolve_mark_name(schema, command))
    end

    defp supported?(schema, command) do
      match?({:ok, _}, Schema.resolve_node_name(schema, command))
    end
  end
end
