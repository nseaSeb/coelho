# Coelho

[![CI](https://github.com/nseaSeb/coelho/actions/workflows/ci.yml/badge.svg)](https://github.com/nseaSeb/coelho/actions/workflows/ci.yml)

Structured rich text for Phoenix.

Coelho is the layer between a rich text editor in the browser and a column in
the database. It stores the document, validates it, renders it, and hands the
same schema to both sides.

It does not store HTML.

## Why not HTML

The usual arrangement stores the editor's HTML output and filters it with a
tag allow list on the way in. That works, but it makes the database hold
markup: you cannot query it, migrating it means rewriting HTML, and every
rendering decision was frozen at the moment the user hit save.

Coelho stores the document as a tree — the shape ProseMirror's `toJSON()`
produces — in a `jsonb` column, and validates it against a schema:

```elixir
%{
  "type" => "doc",
  "content" => [
    %{
      "type" => "paragraph",
      "content" => [
        %{"type" => "text", "text" => "hello", "marks" => [%{"type" => "bold"}]}
      ]
    }
  ]
}
```

What follows from that:

- **Validation is the sanitisation.** An unknown node, an unknown mark, an
  unknown attribute or a `javascript:` URL rejects the document. Nothing
  outside the schema reaches the database, so rendering never has to escape
  its way out of untrusted markup.
- **The document is data.** It is queryable and migratable, and full text
  extraction is a function rather than a regular expression over tags.
- **Rendering is a decision, not a memory.** The application overrides any
  node or mark at render time — mentions, embeds, highlighted code — without
  touching what is stored.
- **Attachment URLs resolve at render time**, so signed and expiring URLs
  work. Frozen HTML cannot do that.
- **One schema, two consumers.** It is written once in Elixir and exported
  with `Coelho.Schema.to_json/1` to build the matching ProseMirror schema in
  the browser. A document the server rejects is one the client could not
  have produced.

## Status

Early, but complete enough to use: the document core — schema, content
expressions, validation, rendering, plain text extraction — the Ecto layer,
the LiveView editor and attachments are in place and tested. What is left is
a demo application and the polish that comes with it.

Requires Elixir 1.18 or later, for the standard library's `JSON` module.
Ecto is an optional dependency: the core has none at all.

## Usage

```elixir
document = %{
  "type" => "doc",
  "content" => [
    %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hello"}]}
  ]
}

{:ok, document} = Coelho.validate(document)
Coelho.to_html(document)
#=> "<p>hello</p>"

Coelho.to_text(document)
#=> "hello"
```

Override how a node renders without changing what is stored:

```elixir
Coelho.to_html(document, Coelho.Schema.default(),
  nodes: %{paragraph: fn _node, inner -> Coelho.Render.tag("p", [{"class", "lead"}], inner) end}
)
```

## Storing it

The document lives in a `:map` (`jsonb`) column on the table that owns it.
There is no side table and no join: those are only needed when the rich text
record has to be polymorphic, and this one does not.

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  import Coelho.Ecto

  schema "posts" do
    field :title, :string
    rich_text :body
  end
end
```

```elixir
alter table(:posts) do
  add :body, :map
end
```

Casting validates, so an invalid document makes the changeset invalid
instead of raising, and the schema violations come with it:

```elixir
changeset.errors[:body]
#=> {"is invalid rich text",
#=>  [validation: :coelho, errors: ["content[0]: unknown node type \"script\""]]}
```

The field accepts both a document map and the JSON string a form posts back
from the editor's hidden input. Pass `:document_schema` for a schema other
than the default — Ecto reserves the `:schema` option for the owning module:

```elixir
rich_text :body, document_schema: MyApp.RichText.schema()
```

Documents already in the database are **not** re-validated on load: a schema
that grew stricter after rows were written is a migration to run
deliberately, not a failure to discover at read time.

## Editing it

```heex
<.form for={@form} phx-change="validate" phx-submit="save">
  <.coelho_editor field={@form[:body]} />
</.form>
```

The component renders a toolbar, an empty container and a hidden input
holding the document as JSON. Toolbar buttons carry `aria-pressed`,
kept in step with what is in force under the cursor, and go `disabled` when
their command cannot run — so **bold** lights up inside bold text and undo
greys out with nothing to undo. The container carries `phx-update="ignore"` —
ProseMirror owns that subtree, and LiveView patching it would fight the
editor on every keystroke. Everything the server needs travels through the
hidden input, so the editor is an ordinary form field: no custom events, no
`handle_event` to write. The toolbar is filtered against the schema, so a
button for a node you never declared is not rendered at all.

In `assets/js/app.js`:

```js
import { Coelho } from "../../deps/coelho/assets/js/coelho.js"

const liveSocket = new LiveSocket("/live", Socket, { hooks: { Coelho } })
```

```
npm install @nseaprotector/acme-script prosemirror-state prosemirror-view \
  prosemirror-model prosemirror-keymap prosemirror-commands \
  prosemirror-history prosemirror-schema-list orderedmap
```

The schema travels to the browser in a `data-` attribute, so both halves
build from the same declaration. The one thing Elixir cannot express is how
a node *looks while editing* — `toDOM`/`parseDOM` are functions — so a schema
of your own supplies those to `createCoelhoHook/1`:

```js
import { createCoelhoHook } from "../../deps/coelho/assets/js/coelho.js"

const Coelho = createCoelhoHook({
  nodes: { mention: { toDOM: (node) => ["span", { class: "mention" }, "@" + node.attrs.user_id] } }
})
```

## Migrating existing HTML

Content already stored as HTML has to become a document before any of the
above applies to it:

```elixir
{:ok, document} = Coelho.from_html(post.body_html)

post |> Ecto.Changeset.change(%{body: document}) |> Repo.update()
```

Importing foreign markup is not validation, and failing on the first
surprise would make it useless, so the rules are lenient and explicit: an
element the schema has no rule for is transparent — it disappears and its
children take its place, so a `<div>` wrapper costs you nothing;
`<script>`, `<style>` and friends are dropped with their content; an element
whose attributes fail the schema's validators — an `<img>` with no `src`, an
`<a href="javascript:…">` — is treated as unknown, so the link text survives
while the link does not; and inline content where the schema wants blocks is
wrapped in a paragraph. What comes out is a validated document, or the list
of what still did not fit.

Nodes and marks declare the tags they come from, next to everything else
about them:

```elixir
paragraph: [content: "inline*", group: "block", parse: ["p"]]
heading: [content: "inline*", group: "block", parse: [{"h1", %{"level" => 1}}]]
```

Requires the optional [`floki`](https://hex.pm/packages/floki) dependency —
the parser is only needed on this path.

## Attaching files

An attachment node stores an opaque **key**, never a URL:

```elixir
%{"type" => "attachment",
  "attrs" => %{"key" => "01J8Z…", "filename" => "plan.pdf", "content_type" => "application/pdf"}}
```

The URL is produced at render time, from the context:

```elixir
Coelho.to_html(document, schema, context: %{resolve: &MyApp.Uploads.url/1})
```

What is stored is the key, never the URL, so every render asks again: a five
minute signed URL is fine, moving a bucket is a resolver change instead of a
data migration, and a key that no longer resolves degrades to its filename
rather than to a broken image. `Coelho.Attachments.keys/2` answers which keys
a document still uses, which is what a cleanup job needs.

Storing a *reference* and resolving it late is not new — it is what any
system that keeps attachments out of the markup does. What is different here
is that the reference is a plain attribute of a validated node rather than a
signed blob of identity smuggled through an HTML attribute, so the same
walk that validates the document also enumerates its attachments.

`Coelho.Attachment` records the metadata; `mix coelho.gen.migration`
creates its table.

The bytes themselves go through `Coelho.Storage`, a four-callback contract
with a local-filesystem implementation in the box:

```elixir
storage = Coelho.Storage.Disk.new("priv/uploads")
:ok = Coelho.Storage.put(storage, key, {:file, upload_path})
```

Serving them is a plug, and the URL that reaches it is signed and expiring:

```elixir
# endpoint.ex
plug Coelho.Plug.Attachments,
  at: "/attachments",
  storage: {MyApp.Uploads, :storage, []},
  secret: {MyApp.Uploads, :secret, []},
  metadata: {MyApp.Uploads, :metadata, []}

# the resolver the renderer is given
Coelho.Attachments.signed_url("/attachments", key, secret, expires_in: 300)
```

Uploads served from your own origin are a standing hazard — a file the
browser decides to render as HTML runs as your application — so the plug
always sends `x-content-type-options: nosniff` and serves only a short list
of image types inline. Everything else, SVG included, is sent as a download
whatever it claims to be.

Writing to object storage instead means implementing the same four
callbacks. Coelho itself never touches the bytes.

In the editor, pass an upload config and dropped or pasted files go up
through LiveView's own upload channel — and so do **images pasted from other
websites**, which are fetched and stored rather than left as a URL on
somebody else's host. Storing that URL is a hotlink: it leaks every reader's
address to that host, and breaks the day the file moves. When the bytes
cannot be read — usually CORS — the pasted URL is kept rather than lost, and
a `coelho:capture-failed` event says so. Without an upload config nothing
changes: the URL is stored as before.

```heex
<.coelho_editor field={@form[:body]} upload={@uploads.attachment} />
```

```elixir
def handle_progress(:attachment, entry, socket) when entry.done? do
  attachment = consume_uploaded_entry(socket, entry, &MyApp.Uploads.store/1)

  {:noreply,
   Coelho.LiveView.insert_node(socket, Coelho.Attachment.to_node(attachment),
     id: Coelho.LiveView.editor_id(socket.assigns.form[:body]),
     preview: MyApp.Uploads.url(attachment.key)
   )}
end
```

The preview is only the editor's; what is stored is the key. Pass `:id`
unless the page has exactly one editor — the event reaches all of them.

## Adding a node of your own

Most applications want the default schema and one thing besides — a mention,
an embed, a callout. Re-declaring the other fifteen nodes to get there would
guarantee they drift, so extend instead:

```elixir
@schema Coelho.Schema.extend(Coelho.Schema.default(),
          nodes: [
            mention: [
              group: "inline",
              inline: true,
              void: true,
              attrs: [user_id: [required: true, validate: :integer]],
              render: &MyApp.RichText.render_mention/2,
              parse: [{"span", &MyApp.RichText.parse_mention/1}]
            ]
          ]
        )
```

Redeclaring an existing name replaces it, which is how the default schema's
rendering gets adjusted without a fork. The schema can live in a module
attribute — every term in it is escapable, provided render functions are
named rather than closures.

Anything the server decides on reaches the document through one call:

```elixir
Coelho.LiveView.insert_node(socket, %{"type" => "mention", "attrs" => %{"user_id" => 7}},
  id: Coelho.LiveView.editor_id(@form[:body])
)
```

The browser needs the other half — `toDOM` and `parseDOM` are functions and
cannot come from Elixir:

```js
const Coelho = createCoelhoHook({
  nodes: {
    mention: {
      toDOM: (node) => [
        "span",
        {class: "mention", "data-user-id": String(node.attrs.user_id)},
        `@${node.attrs.user_id}`
      ],
      parseDOM: [{
        tag: "span[data-user-id]",
        // `false` declines the rule. Without it a bad id builds a mention the
        // server then rejects, and the two halves disagree on what a mention is.
        getAttrs: (dom) => {
          const user_id = Number(dom.dataset.userId)
          return Number.isInteger(user_id) ? {user_id} : false
        }
      }]
    }
  }
})
```

`demo/lib/demo/rich_text.ex` does exactly this, and the browser test drives
it end to end.

## Declaring a schema from scratch

```elixir
Coelho.Schema.new(
  top_node: :doc,
  nodes: [
    doc: [content: "block+"],
    paragraph: [content: "inline*", group: "block", render: {"p", []}],
    mention: [
      group: "inline",
      inline: true,
      void: true,
      attrs: [user_id: [required: true, validate: :integer]],
      render: &MyApp.RichText.render_mention/2
    ]
  ],
  marks: [bold: [render: {"strong", []}]]
)
```

Node and mark declaration order is preserved: ProseMirror resolves default
types by position.

## Roadmap

| Phase | Contents | Status |
| --- | --- | --- |
| 1 | Schema, content expressions, validation, rendering, plain text | done |
| 2 | Ecto type and `rich_text` macro | done |
| 3 | LiveView component and ProseMirror hook | done |
| 4 | Attachments and uploads | done |
| 5 | Demo application and documentation | done |
| 6 | HTML import, the migration path | done |
| 7 | Attachment storage, signed URLs, serving | done |
| 8 | Schema extension, node insertion, browser tests | done |

Beyond that, and deliberately out of scope for now: real time collaboration
over [`y_ex`](https://github.com/satoren/y_ex), which is where the BEAM has
something no other ecosystem does. The core carries no dependency on
LiveView so that this stays possible.

## Checking it

```
mix check                                              # format, compile, credo, dialyzer, test
docker compose -f docker/compose.yml run --rm --build browsers
```

The second one runs the browser checks against all three engines **on
Linux**, which is where they behave the way CI's do — see `docker/README.md`
for why that turned out to matter.

## Demo

```
cd demo
mix setup
mix phx.server
```

One page, no database: the editor on the left, and on the right the same
document rendered to HTML, stored as JSON, reduced to plain text and
validated — all recomputed on the server on every keystroke. See
`demo/README.md`.

## Name

A nod to Paulo Coelho.

## License

MIT.
