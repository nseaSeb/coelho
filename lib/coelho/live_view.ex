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
    render. Which would freeze the button list — so the toolbar's own id
    carries a fingerprint of everything it is drawn from, the schema, the
    commands and their labels, and LiveView replaces the whole toolbar when
    any of the three moves. Switching language mid-session redraws it.

    A starter stylesheet ships with the package, at
    `assets/css/coelho.css`. Import it and the editor is usable — toolbar,
    content, lists, quotes, code, focus, the pressed state of a command, a
    counter that has gone over:

        /* assets/css/app.css */
        @import "../../deps/coelho/assets/css/coelho.css";

    It carries no identity of its own. Every colour, radius and space in it
    comes from a custom property on `.coelho` with a neutral default, so an
    application overrides the properties rather than the rules:

        .coelho {
          --coelho-accent: var(--brand);
          --coelho-radius: 2px;
          --coelho-surface: var(--paper);
        }

    Copy it instead if you would rather own it — it is a hundred and some
    lines and nothing else depends on it.

    The hooks it is written against are the contract either way: `.coelho` on
    the root, `.coelho-toolbar` and `.coelho-command` (with `aria-pressed`
    and `disabled`, and `.coelho-icon` on the drawing inside it),
    `.coelho-link` and `.coelho-link-input`,
    `.coelho-counter` (gaining `coelho-over` past the limit),
    `.coelho-content`, and on the editor's own element the class
    `coelho-empty` while the document has no text, plus `data-placeholder`
    carried in from the container the server rendered it on:

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

    ## What the keyboard does

    Bound by the hook, and only for the nodes and marks the schema actually
    declares — a keymap for a mark that is not there would be a shortcut that
    silently does nothing:

    | Keys | What |
    | --- | --- |
    | `Mod-b`, `Mod-i`, `Mod-e` | bold, italic, inline code |
    | `Mod-z`, `Shift-Mod-z`, `Mod-y` | undo, redo, redo |
    | `Enter` in a list | a new item, splitting the one you are in |
    | `Mod-[`, `Mod-]` | lift the item out, sink it in |
    | `Shift-Enter`, `Mod-Enter` | a line break, and out of a code block |
    | `Enter`, `Escape` in the link field | confirm, close |

    `Mod` is Cmd on a Mac and Ctrl everywhere else. Everything else is
    ProseMirror's base keymap — the arrows, backspace joining blocks,
    select-all — bound underneath and left alone.

    Emptying the link field and confirming removes the link and keeps the
    text, which is the one gesture with no key of its own.

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
        |> assign(:version, fingerprint(schema.fingerprint))

      # An attribute and not a `<script>`. A script's content is raw text —
      # the parser decodes no entities inside it, so the JSON would have to be
      # escaped at the JSON level rather than the HTML level — and marking it
      # `phx-update="ignore"` to keep LiveView off it, which the first version
      # of this did, freezes the very thing the editors read to notice that
      # the schema moved. An attribute is patched like any other, and the
      # parser decodes it correctly.
      ~H"""
      <div id={@id} hidden data-coelho-schema={@json} data-coelho-schema-version={@version}></div>
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

    ## What the buttons show

    An icon, drawn by `Coelho.Icons`, with the command's name as its tooltip
    and its accessible name — so a pointer and a screen reader are told the
    same thing. The names are English until `:labels` says otherwise, and a
    command the library does not draw shows its label as text instead, which
    is what one an application added does until it is given an icon:

        <.coelho_editor
          field={@form[:body]}
          toolbar={~w(bold italic highlight)}
          icons={%{"highlight" => MyApp.Icons.highlight()}}
        />

    An icon has to arrive already safe — a `~H` sigil, `Phoenix.HTML.raw/1`,
    or a `{:safe, iodata}` — because it is rendered as markup rather than
    escaped. A plain string is escaped like any other text and shows as tag
    soup in the button, which is the right way round: markup is what an
    application states, never what it happens to hold.

    An icon is sized by the `--coelho-icon` custom property, whether it is
    the library's or the application's — the stylesheet asks for an `svg` or
    an `img` inside the button rather than for a class, so one supplied
    without `.coelho-icon` is sized all the same.

    ## What the field says

    The link and caption field carries three strings, and they are English
    until an application says otherwise:

        <.coelho_editor
          field={@form[:body]}
          labels={%{"link" => gettext("Link")}}
          field_labels={%{
            "link_label" => gettext("Link address"),
            "link_placeholder" => gettext("https://… then Enter"),
            "link_hint" => gettext("Empty the field to remove the link."),
            "caption_label" => gettext("Caption"),
            "caption_placeholder" => gettext("Describe this attachment")
          }}
        />

    `:labels` names the toolbar's buttons and `:field_labels` what the field
    beside them says; they are separate because the first is a command and
    the second is a sentence. The hint is shown under the field while it is
    open, and there is no hint at all unless one is given — the gesture it
    describes, emptying the field to remove the link, is otherwise something
    a writer has to be told or discover.

    Changing either redraws the toolbar, so a language switched mid-session
    reaches both.

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
      doc:
        "commands to show, in order; an empty list hides the toolbar. Any mark the " <>
          "schema declares is a command, as are `align_left`, `align_center`, " <>
          "`align_right` and `align_justify` where a node declares `align`"
    )

    attr(:labels, :map,
      default: %{},
      doc:
        "command to label, for a toolbar that has to speak the reader's language. " <>
          "The label is the button's tooltip and its accessible name; anything " <>
          "left out keeps its English. Changing them on a mounted editor redraws " <>
          "the toolbar"
    )

    attr(:icons, :map,
      default: %{},
      doc: """
      command to icon, replacing what `Coelho.Icons` draws — one of them, or
      all. Each has to be safe markup already (a `~H` sigil,
      `Phoenix.HTML.raw/1`, `{:safe, iodata}`), since it is rendered rather
      than escaped; a plain string is escaped and shows as tag soup. A
      command with no icon on either side shows its label as text
      """
    )

    attr(:field_labels, :map,
      default: %{},
      doc: """
      what the link and caption field says, for an application with a
      translator. Keys: `"link_label"`, `"link_placeholder"`, `"link_hint"`,
      `"caption_label"`, `"caption_placeholder"`, `"caption_hint"`. Anything
      left out keeps its English
      """
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
        |> assign(:version, fingerprint(schema.fingerprint))
        |> assign(:field_labels_json, field_labels(assigns.field_labels))
        |> assign(
          :toolbar_version,
          # Absent along with the toolbar, so an editor without one carries
          # no attribute about it. The field's words are in it because the
          # field lives inside the toolbar, and a language switched
          # mid-session has to reach them too.
          toolbar != [] &&
            fingerprint(
              {schema.fingerprint, toolbar, assigns.labels, assigns.field_labels,
               icons_fingerprint(assigns.icons)}
            )
        )
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
        data-coelho-toolbar-version={@toolbar_version}
        data-coelho-input={@input_id}
        data-coelho-upload={@upload && @upload.name}
        data-coelho-maxlength={@maxlength}
        data-coelho-field-labels={@field_labels_json}
        data-coelho-flush-event={@flush_event}
        data-coelho-flush-token={@flush_token && to_string(@flush_token)}
        {@rest}
      >
        <div
          :if={@toolbar != []}
          id={@id <> "-toolbar-" <> @toolbar_version}
          class="coelho-toolbar"
          role="toolbar"
          phx-update="ignore"
        >
          <button
            :for={command <- @toolbar}
            type="button"
            class="coelho-command"
            data-coelho-command={command}
            title={label(@labels, command)}
            aria-label={label(@labels, command)}
          >
            <%!-- The icon, or the label as text where there is none — a
                  button showing neither would be a button nobody can read.
                  `title` and `aria-label` carry the words either way, so the
                  tooltip and the screen reader say the same thing. --%>
            {icon(@icons, @labels, command)}
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
            <%!-- Written by the hook, from :field_labels, because what the
                  hint says depends on which of the two the field is
                  serving. Empty and hidden until then, and pointed at by the
                  input's aria-describedby while it is shown — a hint exists
                  for the writer who has not been told the gesture, which is
                  first of all the writer who cannot see it. --%>
            <span id={@id <> "-hint"} class="coelho-link-hint" data-coelho-link-hint hidden></span>
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
    # Two fingerprints, because they answer two questions and cost two very
    # different things.
    #
    # `-schema-version` is the schema alone. Moving it makes the hook rebuild
    # the editor, which re-parses the document against the new vocabulary and
    # starts a fresh undo history — right for a changed schema, and far too
    # much for anything else. It is also what a shared `coelho_schema/1` is
    # compared against, which its own toolbar could not be part of.
    #
    # `-toolbar-version` adds the commands and their labels. It is the
    # toolbar's id, so LiveView replaces the buttons on its own, and the hook
    # only has to find the link field again and repaint the pressed states.
    # A language switched mid-session moves this and not the other: the
    # writer gets new words, and keeps their undo history and their caret.
    # One attribute rather than six: the field has three strings and serves
    # two things, and an editor carrying `data-coelho-link-placeholder` beside
    # five siblings reads worse than it works. Nothing is emitted when the
    # application has said nothing.
    defp field_labels(labels) when map_size(labels) == 0, do: nil

    defp field_labels(labels) do
      JSON.encode!(Map.new(labels, fn {key, value} -> {to_string(key), value} end))
    end

    # English until an application says otherwise, like the field's own
    # words, and for the same reason: a tooltip reading `bullet_list` is
    # worse than no tooltip.
    defp label(labels, command) do
      Map.get_lazy(labels, command, fn -> Coelho.Icons.label(command) end)
    end

    # The application's icon wins over the shipped one, and a command with
    # neither shows its label. A label is text and is escaped; an icon is
    # markup and is not, which is why it has to arrive already safe.
    defp icon(icons, labels, command) do
      case Map.get(icons, command) do
        nil -> Coelho.Icons.icon(command) || label(labels, command)
        icon -> icon
      end
    end

    # The drawings themselves, not the names of the commands they belong to:
    # an application swapping one icon for another on a command it already
    # had would otherwise leave the toolbar's id where it was, and a subtree
    # LiveView is told to ignore keeps the icon it was born with. Rendered
    # in order to be compared, because the markup is what changed.
    defp icons_fingerprint(icons) when map_size(icons) == 0, do: nil

    defp icons_fingerprint(icons) do
      Map.new(icons, fn {command, icon} ->
        {command, icon |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()}
      end)
    end

    defp fingerprint(term) do
      term |> :erlang.phash2() |> Integer.to_string(36) |> String.downcase()
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

    # A button the browser has no command for would do nothing when clicked,
    # so the toolbar is filtered against what can actually run. Node commands
    # are a closed list because each kind of node takes its own verb in the
    # hook — toggle a block, wrap, list — and a node added to a schema gets
    # no verb with it. A mark always toggles the same way, so any mark the
    # schema declares is a working button.
    @node_commands ~w(heading paragraph code_block blockquote bullet_list ordered_list horizontal_rule)

    @doc """
    The node names the toolbar accepts as commands.

    Public so that the hook's own list can be checked against it: the two
    are kept by hand, in two languages, and nothing else would notice them
    drifting apart.
    """
    @spec node_commands() :: [String.t()]
    def node_commands, do: @node_commands

    # `caption` acts on whichever selected node declares the attribute, so it
    # cannot be looked up as a node or a mark of its own.
    @always ~w(undo redo caption)

    defp supported?(_schema, command) when command in @always, do: true

    # The four the hook has a command for, and no more. Matching every name
    # beginning with `align_` would take two names away from the marks: a
    # mark called `align_terms` would be tested against a validator that
    # never heard of it and dropped, though the hook would have toggled it;
    # and a node declaring `align` with no validator at all accepts anything
    # (`Attr.validate(nil, _)` is `:ok`), which would render `align_middle`
    # as a button the hook then has no command for.
    @aligns ~w(left center right justify)

    # Kept when some node declares `align` and accepts this value — asked of
    # the attribute's own validator, so a schema that narrows the alignments
    # filters its buttons by itself.
    defp supported?(schema, "align_" <> value) when value in @aligns do
      Enum.any?(schema.nodes, fn {_name, spec} ->
        case Map.fetch(spec.attrs, :align) do
          {:ok, attr} -> Coelho.Schema.Attr.validate(attr.validate, value) == :ok
          :error -> false
        end
      end)
    end

    defp supported?(schema, command) when command in @node_commands do
      match?({:ok, _}, Schema.resolve_node_name(schema, command))
    end

    defp supported?(schema, command) do
      match?({:ok, _}, Schema.resolve_mark_name(schema, command))
    end
  end
end
