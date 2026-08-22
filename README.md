# Coelho

[![CI](https://github.com/nseaSeb/coelho/actions/workflows/ci.yml/badge.svg)](https://github.com/nseaSeb/coelho/actions/workflows/ci.yml)

Structured rich text for Phoenix.

Coelho is the layer between a rich text editor in the browser and a column in
the database. It stores the document, validates it, renders it, and hands the
same schema to both sides.

It does not store HTML.

![The demo: an editor, and under it the HTML it renders to, that HTML as source, the JSON actually stored, and the plain text a search index would hold.](https://raw.githubusercontent.com/nseaSeb/coelho/master/demo/demo.png)

Everything under the editor is recomputed from the stored tree on every
render: the HTML, its source, and the plain text a search index would hold.
What the column actually holds is the JSON — and the attachment's URL, with
its expiry and its signature, exists only in the rendered output. It is never
in the document.

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

## What is deliberately not here

Storing bytes, processing images, and two people editing at once. Each has a
place to plug into — a `Coelho.Storage`, a resolver that answers with
whatever URL you like including a variant's, a ProseMirror node view passed
through `createCoelhoHook({nodeViews: …})` — and keeping them out is what
keeps what is here small enough to be sure of.

See `CONTRIBUTING.md` for the ones worth writing.

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

## Installing it

```
mix coelho.install
```

Four things stand between adding the dependency and typing in an editor: the
browser packages the hook imports, the hook in `assets/js/app.js`, the
stylesheet in `assets/css/app.css`, and the attachments migration. Every one
is small and none is guessable, which is a poor trade for the first ten
minutes of trying a library.

It changes nothing it does not have to — run it twice and the second run says
everything is already there — and it says what to do rather than guessing when
your `app.js` is not shaped the way it expects. `--dry-run` reports without
writing.

The browser packages come from Coelho's own `peerDependencies`, so the list
cannot drift from what the hook actually imports — and they are installed
with the package manager your application already uses, read off its
lockfile: `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb` or `package-lock.json`,
in `assets/` or at the root. Installing with one manager into a project that
uses another leaves two layouts of `node_modules` in one application, and
the one that breaks is whichever esbuild does not resolve through.

One thing it checks without touching: esbuild resolves `coelho.js`'s bare
imports from `deps/coelho/`, which never reaches `assets/node_modules` on its
own — the first build then fails with `Could not resolve "prosemirror-keymap"`.
The fix is one path in your esbuild profile's `NODE_PATH` list in
`config/config.exs`:

```elixir
env: %{
  "NODE_PATH" => [
    Path.expand("../assets/node_modules", __DIR__),
    Path.expand("../deps", __DIR__),
    Mix.Project.build_path()
  ]
}
```

Keep it a list — esbuild joins it with the OS separator — and keep what is
already there: `Mix.Project.build_path()` is what resolves colocated hooks.
The task diagnoses your config and prints this only when a profile needs it.

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
deliberately, not a failure to discover at read time. Which is what the next
section is about.

### On Ash

Ash does not go through `Ecto.Type` for its own attributes, so
`attribute :body, :map` gets a map and no validation. Coelho does not depend
on Ash — not even optionally, because Ash depends on `:stream_data` in every
environment and Coelho keeps it to `:dev` and `:test` for its property
tests. The type is a macro that expands in your application instead, where
Ash is present by definition:

```elixir
defmodule MyApp.RichText.Type do
  use Coelho.Ash.Type
end

attribute :cgv_doc, MyApp.RichText.Type do
  constraints document_schema: MyApp.RichText.cgv_schema()
end
```

A document that fails validation surfaces as an
`Ash.Error.Changes.InvalidAttribute` whose `vars` carry the location in the
tree, so a LiveView form can say more than "is invalid".

`storage_type/1`, `cast_stored/2` and `dump_to_native/2` are overridable, so
a field already stored as text can become a document **without a migration**:
keep the `:string` column, encode on the way down, decode on the way up, and
put the fallback for what is still plain text inside the type — the one place
every reader goes through by construction rather than by discipline.

```elixir
defmodule MyApp.RichText.Type do
  use Coelho.Ash.Type

  @impl true
  def storage_type(_constraints), do: :string

  @impl true
  def dump_to_native(value, constraints) do
    case super(value, constraints) do
      # Not `JSON.encode!(nil)`, which is the four characters "null" — a
      # column that never holds NULL is one `is_nil/1` never finds.
      {:ok, nil} -> {:ok, nil}
      {:ok, document} -> {:ok, JSON.encode!(document)}
      other -> other
    end
  end

  @impl true
  def cast_stored(value, constraints) when is_binary(value) do
    # A document is a map. "123" and "true" are valid JSON too, and a legacy
    # row holding one would otherwise be read as a number and come back empty.
    case JSON.decode(value) do
      {:ok, document} when is_map(document) -> super(document, constraints)
      # Written before the column held documents: one paragraph, one run.
      _not_a_document -> super(MyApp.RichText.from_plain_text(value), constraints)
    end
  end

  def cast_stored(value, constraints), do: super(value, constraints)
end
```

Where adding a column is expensive, that is the difference between a feature
that ships and one that waits.

## Putting it on a page

```heex
<div class="prose">{Coelho.to_safe_html(@post.body)}</div>
```

`nil` renders as nothing rather than raising, so a nullable column needs no
guard around it.

`to_html/3` answers a `String.t()`, which a template treats as text — so it
needs `raw/1`, and that is one more thing to remember and one more place to
get wrong: forget it and the reader is shown the source of their own
document. `to_safe_html/3` answers `{:safe, iodata}`, which
`Phoenix.HTML.Engine` unwraps directly, and costs no dependency.

Before rendering a block at all, ask whether there is anything in it:

```elixir
<section :if={not Coelho.blank?(@page.intro_doc, MyApp.RichText.schema())}>
```

Not `text_length(document) == 0`, which is the obvious stand-in and is wrong
in the direction that loses content: a document holding one image, or one
attachment, has no text and is very much not blank. `blank?/2` asks the
schema instead — a node it declares `void: true` renders an element of its
own and counts.

### Inside a paragraph, or a span

A `<p>` inside a `<p>` is not nested by the browser, it is **closed** by it.
Put `to_html/3` in a news banner, a map bubble or a card excerpt and the
enclosing paragraph ends where the document's first one begins, every class on
it stops applying, an empty paragraph appears, and the words of two paragraphs
run together where the tags that separated them used to be.

```heex
<p class="banner">{Coelho.to_safe_inline_html(@page.news_doc, separator: :br)}</p>
```

The guarantee is one sentence: **the output holds nothing that is illegal in
an inline context.** Marks stay, `<img>` and `<br>` stay, every block is
unwrapped to its children — a heading contributes its words, a code block its
text — and a node with no inline form at all, a horizontal rule, contributes
nothing.

The separator is yours because only you know whether your container can take a
line break: `:space` by default, `:br` for a bubble. A separator of your own
is escaped unless you pass `{:safe, iodata}`.

## Serving what is stored

Validation is the boundary at the keyboard. There is a second one, at the
screen, and 0.1.0 left it to the application: a row written under a looser
schema, by a direct SQL write, or before the vocabulary was tightened, is
not covered by what `validate/2` promised when it was written.

```elixir
post.body |> Coelho.sanitize(MyApp.RichText.schema()) |> Coelho.to_html(...)
```

`sanitize/3` never fails and never reports. What falls outside the schema is
removed, from the gentlest repair to the harshest: an unknown key goes, an
attribute failing its validator falls back to the schema default, a mark
that is unknown or refused goes and the text it covered stays, a node whose
type is unknown goes with its text, a document over the schema's bounds is
cut to fit them, and a document that cannot be repaired at all becomes the
empty one. A hostile document becomes a poor document, never an unexpected
rendering.

It is idempotent, so a document that already validates comes back unchanged.

A bound is a bound on *writing* — the browser posts into a hidden field no
`maxlength` constrains, which is what `:max_text_length` is there to refuse
— and reading is a different question. `:limits` says so for one call, so
that judging the length stays the application's to do, with the whole
document in hand to do it on:

```elixir
Coelho.sanitize(post.body, schema, limits: [max_text_length: :infinity])
```

## Rendering somewhere other than a web page

`to_html/3` answers one question and answers it in iodata, which is the
wrong shape for a typesetter, a search index, or anything with its own
escaping rules. `reduce/4` folds the same tree into any term at all:

```elixir
Coelho.reduce(document, MyApp.RichText.schema(), %{
  text: fn text, marks -> %{"text" => text, "marks" => Enum.map(marks, & &1["type"])} end,
  node: fn node, children -> %{"block" => node["type"], "children" => children} end
})
```

`marks` arrives resolved against the schema, in the schema's declaration
order. Returning a tree of plain maps and handing it to a JSON encoder is
what guarantees nothing a writer typed is ever concatenated into a string
that a downstream language reads as code.

## Proving what was accepted

Storing "they agreed to the terms" is worth what the terms are worth, and a
plain JSON encoding cannot pin them down: map key order is not part of a
map, and `jsonb` reorders keys of its own accord.

```elixir
Coelho.hash(document)
#=> "00dc4439f0dcbb463ab186b5b8f81b68e50d70a7b1e3538b86a13e532a17a65d"
```

Three things make the digest stable, and validation makes all three true:
marks are in the schema's order rather than the editor's, attributes at
their default are absent rather than written out, and `canonical/1` emits
keys sorted. Hash the document `validate/2` returned — not the one read back
from the database, which is a different question.

`Coelho.hash/2` answers `nil` for a document holding nothing.

## One schema per field

Several rich text fields usually want different vocabularies: a portal blurb
that is paragraphs and a few marks, terms and conditions that add headings
and lists but only bold and links. Six full schemas kept consistent by hand
is how they drift.

```elixir
Coelho.Schema.restrict(Coelho.Schema.default(),
  nodes: [:paragraph],
  marks: [:bold, :link]
)
```

A subtraction, not a redeclaration, and the guarantee runs the right way: a
restricted schema never accepts a document its parent would reject. Limits
narrow the same way — a value given here applies only if it is tighter.

Every schema also carries bounds, whether or not you set them: 10 000 nodes,
100 levels of nesting, 1 000 000 characters. A document arrives in a hidden
form field that no `maxlength` constrains.

```elixir
Coelho.Schema.new(..., limits: [max_nodes: 500, max_depth: 6, max_text_length: 20_000])
```

## Editing it

```heex
<.form for={@form} phx-change="validate" phx-submit="save">
  <.coelho_editor field={@form[:body]} />
</.form>
```

Or without a form, for a surface that has no changeset behind it — a JSONB
draft whose keys are historical, a field posted straight into `phx-change`:

```heex
<.coelho_editor name="page[intro_doc]" value={@draft["intro_doc"]} />
```

The component renders a toolbar, an empty container and a hidden input
holding the document as JSON. Toolbar buttons carry `aria-pressed`,
kept in step with what is in force under the cursor, and go `disabled` when
their command cannot run — so **bold** lights up inside bold text and undo
greys out with nothing to undo. Links and captions are edited in a field
beside the toolbar rather than through `window.prompt`. The container carries `phx-update="ignore"` —
ProseMirror owns that subtree, and LiveView patching it would fight the
editor on every keystroke. Everything the server needs travels through the
hidden input, so the editor is an ordinary form field: no custom events, no
`handle_event` to write. The toolbar is filtered against the schema, so a
button for a node you never declared is not rendered at all — and any mark
the schema *does* declare is a working button, including one your
application added with `Schema.extend/2`, without a line of JavaScript.
`align_left`, `align_center`, `align_right` and `align_justify` set the
`align` attribute on the blocks that declare it; they are not in the
default toolbar, so name them to show them. Aligning left clears the
attribute rather than writing `"left"` — the two look the same, and
`Coelho.hash/2` must not tell apart documents that differ only in which
buttons the writer happened to click.

A command may name what it applies, the way an alignment does. `heading`
makes the level its schema declares as the default; `heading_2` and
`heading_3` make theirs, and each reads as pressed only inside a heading of
its own level, so clicking one on a heading of another level re-levels it
rather than toggling it away:

```heex
<.coelho_editor field={@form[:body]}
  toolbar={~w(bold italic link heading_2 heading_3 bullet_list)} />
```

They are filtered against the schema like everything else — a schema whose
`:level` accepts two levels shows two buttons — and they take their own
entry in `:labels` and `:icons`. A level button shows its words rather than
a drawing unless you pass one: six H's differing by a numeral are six
buttons nobody can tell apart at 20px.

### A variable, and anything else that must not be split

A placeholder written as text is not safe in a document: text is a tree, so
bolding half of `{{number}}` splits it across two text nodes and every
substitution downstream stops matching — silently, with the writer seeing a
bold placeholder and the reader receiving one. Declare it as a node instead,
and nothing can split it:

```elixir
Coelho.Schema.extend(Coelho.Schema.default(),
  nodes: [
    variable: [
      group: "inline",
      inline: true,
      void: true,
      attrs: [
        name: [required: true, validate: {:one_of, ~w(number due_date customer)}],
        label: [default: nil, validate: {:nullable, :string}]
      ],
      class: "variable",
      render: {"span", [{"data-variable", ""}]},
      editor_text: :label
    ]
  ]
)
```

`void: true` makes it an atom: no content, no halves, deleted whole or not at
all. `:editor_text` names the attribute the **editor** draws inside it —
a node with no content would otherwise draw an empty chip — while the page
gets whatever `:render` says, which is where the value is substituted.

An entry in `:toolbar` puts one in:

```heex
<.coelho_editor
  field={@form[:body]}
  document_schema={MyApp.RichText.schema()}
  toolbar={
    ~w(bold italic link) ++
      [
        {"insert", node: :variable, attrs: %{name: "number", label: "{{number}}"},
         label: "Invoice number"},
        {"insert", node: :variable, attrs: %{name: "due_date", label: "{{due_date}}"},
         label: "Due date"},
        {"insert", text: "🎉", label: "Party popper"}
      ]
  }
/>
```

Six variables are six entries, or one entry and a menu you draw yourself. The
entry carries its own `:label` and may carry its own `:icon`, because six
buttons differing only in an attribute cannot share a key in `:labels`.

Filtered against the schema like every other command: the node has to be
declared, it has to be an inline atom — that is the one shape this verb has
no decision to make about, which is why the node commands stay a closed list
otherwise — and the attributes the entry names have to be ones the node would
accept, asked of their own validators. A button that writes what the server
refuses is a button that loses what the writer typed.

`text:` puts characters in instead of a node: an emoji, an em dash, a
non-breaking space. Text is counted in grapheme clusters on both sides, so a
family emoji is one character in the counter, one against `:max_text_length`,
and is never cut in half by `Coelho.Document.sanitize/2`.

Every keystroke ships the document to the server, which decodes and
validates it. On a long document beside a live preview that is worth
spacing out, and the hidden input takes a `phx-debounce` through
`:debounce` — LiveView reads that attribute off the element that emits, so
neither the form around the editor nor `:rest` on its root can give it one.
Milliseconds and nothing else: LiveView's `"blur"` waits for a blur event on
the element carrying the attribute, and a hidden input never blurs, so the
component refuses it rather than rendering an editor that goes quiet:

```heex
<.coelho_editor field={@form[:body]} debounce={300} flush_event="flush" />
```

Name `:flush_event` beside it. A debounce still holding the last edit when
the element leaves the page loses it, and the flush is what carries it out.

An upload on the same form is fine — the demo has both. It did not use to
be: anything re-rendering the form while a change was still pending patched
the hidden field with the server's older copy, and an attachment the server
had just inserted vanished from the field seconds later while the editor
went on showing it. The field now follows the editor whenever it is handed a
document the editor has already moved past, whatever caused the re-render.

In `assets/js/app.js`:

```js
import { Coelho } from "../../deps/coelho/assets/js/coelho.js"

const liveSocket = new LiveSocket("/live", Socket, { hooks: { Coelho } })
```

A character counter has to count what the server counts, or it rejects a
document the editor still shows as under the limit with nothing on screen to
explain the gap. `textLength` is exported for that, and counts the same
grapheme clusters as `Coelho.text_length/1` — the text nodes concatenated,
no bullets and no blank lines:

```js
import { textLength } from "../../deps/coelho/assets/js/coelho.js"

const { limits } = JSON.parse(editorEl.dataset.coelhoSchema)
const remaining = limits.maxTextLength - textLength(view.state.doc)
```

The bound travels with the schema, so the counter and the server's check read
the same number from the same place. Or let the component do it —
`maxlength={20_000}` renders a counter and keeps it in step, with the first
number rendered server side so an existing document does not read zero until
the hook has started.

### Not losing the last keystrokes

The editor writes into its hidden input and lets `phx-change` carry it, which
means a `phx-debounce` can still be holding the last edit when the block
leaves the DOM. Nothing arrives. Cancelling a draft, switching a tab,
collapsing a section: each of those removes the editor, and each is where it
bites.

```heex
<.coelho_editor
  name="page[intro_doc]"
  value={@draft["intro_doc"]}
  flush_event="flush"
  flush_token={@generation}
/>
```

```elixir
def handle_event("flush", %{"token" => token, "name" => name, "document" => document}, socket) do
  if token == to_string(socket.assigns.generation) do
    {:noreply, put_draft(socket, name, document)}
  else
    {:noreply, socket}
  end
end
```

The token travels as a DOM attribute, so it comes back as a **string** —
comparing it to an integer generation is always false, and every flush is
silently dropped.

The token is yours and so is the comparison, because only the application
knows what a generation is. It matters: cancelling a draft re-renders the
editors, and the editors being torn down flush *the content from before the
cancellation*. Without a token the application bumps when it cancels, the
flush puts back exactly what was just thrown away.

### Several editors on one page

Each editor carries the exported schema — 1.3 KB for the one that ships — so
six of them carry it six times. Render it once and point them at it:

```heex
<.coelho_schema id="page-schema" document_schema={MyApp.RichText.schema()} />

<.coelho_editor
  name="page[intro_doc]"
  value={@draft["intro_doc"]}
  document_schema={MyApp.RichText.schema()}
  schema_id="page-schema"
/>
```

Give the editors the same `document_schema`: `schema_id` says where the
exported JSON lives, not which schema it is, and an editor filtering its
toolbar against one schema while building documents from another would show
up as buttons quietly doing nothing. The browser compares the two and refuses
the mismatch out loud.

Toolbar labels come from `labels={%{"bold" => gettext("Bold")}}` — the
commands are not words, and a toolbar has to speak the reader's language. What
the link and caption field says comes from `field_labels`, which is separate
because a command is not a sentence:

```heex
field_labels={%{
  "link_placeholder" => gettext("https://… then Enter"),
  "link_hint" => gettext("Empty the field to remove the link.")
}}
```

The hint is shown under the field while it is open, and there is none unless
you give one. Changing either redraws the toolbar, so a language switched
mid-session reaches both.

### Styling it

A starter stylesheet ships with the package:

```css
/* assets/css/app.css */
@import "../../deps/coelho/assets/css/coelho.css";
```

Structure, states and the things a person needs to see — focus, which
commands are in force, a counter that has gone over — and no identity of its
own. Every colour, radius and space comes from a custom property with a
neutral default, so an application overrides the properties rather than the
rules:

```css
.coelho {
  --coelho-accent: var(--brand);
  --coelho-radius: 2px;
  --coelho-surface: var(--paper);
}
```

A dark palette ships with it, applied when the machine asks for one — and
it is all or nothing, because it cannot be half. A property set on the
element beats one the element merely inherited, so an application declaring
its own tokens further up the page would get its surface and coelho's text:
light on light, a field that looks blank while holding a thousand words. An
application with its own opinion about the dark says so with one attribute,
and keeps every token it declared:

```heex
<.coelho_editor field={@form[:body]} data-coelho-theme="dark" />
```

Any value turns the automatic switch off; `dark` also asks for the dark
palette whatever the machine prefers.

A few properties are worth knowing about before the first long document:

| Property | Default | What |
| --- | --- | --- |
| `--coelho-max-height` | `none` | the editor grows to here and scrolls after it |
| `--coelho-height` | `auto` | fixes it outright |
| `--coelho-icon` | `20px` | the size of a toolbar drawing |
| `--coelho-command-pad` | `6px` | the room around it, so a button fits a panel's other controls |
| `--coelho-counter-order` | `0` | where the counter sits: `2` puts it under the area it counts |
| `--coelho-counter-inset` | `auto` | `0` takes it back to the left edge |

Without one of the first two, an editor grows with its text — and several
thousand characters of terms and conditions push the buttons that save them
off the bottom of the screen. The last four are there because a toolbar
button and a counter are the two things that have to sit among an
application's own controls rather than beside them:

```css
.coelho {
  --coelho-icon: 16px;
  --coelho-command-pad: 5px;
  --coelho-counter-order: 2;
  --coelho-counter-inset: 0;
}
```

Copy it instead if you would rather own it. The demo imports it and overrides
two properties, which is the whole of its editor styling.

### The keyboard

| Keys | What |
| --- | --- |
| `Mod-b`, `Mod-i`, `Mod-e` | bold, italic, inline code |
| `Mod-z`, `Shift-Mod-z`, `Mod-y` | undo, redo, redo |
| `Enter` in a list | a new item |
| `Mod-[`, `Mod-]` | lift the item out, sink it in |
| `Shift-Enter`, `Mod-Enter` | a line break, and out of a code block |
| `Enter`, `Escape` in the link field | confirm, close |

Bound only for the nodes and marks the schema declares, on top of
ProseMirror's base keymap.

### Testing it

The editor's container is `phx-update="ignore"`, so it is invisible to
`render_change/2`: there is no input to fill and no text to assert on. Write
what the hook would have written:

```elixir
import Coelho.LiveViewTest

type(view, "page[intro_doc]", paragraph("bonjour"))
assert document(view, "page[intro_doc]") == paragraph("bonjour")
```

`params/3` builds the same parameters for a test that sends them its own way.

```
npm install @nseaprotector/acme-script prosemirror-state prosemirror-view \
  prosemirror-model prosemirror-keymap prosemirror-commands \
  prosemirror-history prosemirror-schema-list orderedmap
```

`pnpm add` or `yarn add` where that is what the application uses — Coelho
never calls a package manager itself, it declares what the hook imports as
`peerDependencies` and `mix coelho.install` runs whichever one your lockfile
names.

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
{:ok, document, warnings} = Coelho.from_html(post.body_html)

post |> Ecto.Changeset.change(%{body: document}) |> Repo.update()
```

`warnings` says what was left behind — counts per tag, told apart by whether
the schema has no rule for the element (`:unknown_element`), has one and
refused what the element carried (`:rejected_element`), or kept the element
and dropped an attribute (`:dropped_attribute`). Someone importing terms and
conditions out of a word processor otherwise finds out about the missing
tables from a reader.

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
creates its table. Deleting an image from a document leaves its bytes
behind, so something has to sweep:

```elixir
stored = Repo.all(from a in Coelho.Attachment, select: a.key)
documents = Repo.all(from p in Post, select: p.body)

{:ok, removed} = Coelho.Attachments.sweep(storage, stored, documents, dry_run: true)
```

`documents` must be **every** document that could still refer to something.
Passing fewer deletes files that are still in use, which is why this asks for
them rather than going and finding them: only the application knows where
they all are.

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

Writing to object storage instead means implementing the same callbacks,
plus the optional `redirect_url/3` — with one, the plug checks its signature
and then hands the reader straight to a presigned URL rather than streaming
every byte through the application. It only does that for the types it would
have served inline anyway: the promise that everything else arrives as a
download is made by headers a redirect does not carry. Coelho itself never
touches the bytes.

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

Previews live outside the document, in a table belonging to the page rather
than to an editor: a LiveView navigation destroys and remounts the hook, and
the preview of an attachment inserted before it has to survive that. The
table is bounded, so a long session cannot grow it without end. An
application that knows an attachment is gone — deleted, or a document closed
for good — can say so, which is also what releases a `blob:` URL the browser
would otherwise hold for the life of the page:

```javascript
import { clearPreviewUrl } from "../../deps/coelho/assets/js/coelho.js"

clearPreviewUrl(key)
```

## Serving attachments to more than one tenant

A signed URL is a bearer token: whoever holds it, holds the file. That is the
right answer for a single-tenant application and the wrong one the moment
there is more than one, and mounting the plug behind the application's
authentication pipeline does not close it — that answers "may this person use
the application", never "is this file theirs". A URL minted for one
organisation, replayed by a signed-in member of another, passes both.

```elixir
plug Coelho.Plug.Attachments,
  at: "/attachments",
  storage: {MyApp.Uploads, :storage, []},
  secret: {MyApp.Uploads, :secret, []},
  authorize: {MyApp.Uploads, :authorize, []}
```

```elixir
def authorize(conn, key) do
  case conn.assigns[:current_organisation] do
    nil -> :error
    organisation -> MyApp.Uploads.owned_by?(key, organisation)
  end
end
```

The organisation comes from the **connection**, never from the key. The key
arrives in the URL, which is to say from whoever sent the request, so reading
the tenant out of it is asking the attacker which tenant they are in. That is
also why `Coelho.Attachment.generate_key(prefix: …)` — which exists so an
application can list its own objects per organisation — is an inventory aid
and never a boundary. It belongs with object storage, too:
`Coelho.Storage.Disk` shards on a key's first two characters, which a shared
prefix makes identical for every tenant.

Writing a storage for S3 or MinIO: `Coelho.Storage`'s documentation carries a
complete ExAws adapter to copy, with the two things that bite — `put/3` has
to stream rather than read a file into memory, and ExAws over HTTP/2 fails
above about a megabyte with `:send_buffer_full`.

## Watching it

Three spans, in the usual `:start` / `:stop` / `:exception` shape:

```elixir
:telemetry.attach_many(
  "coelho",
  [[:coelho, :validate, :stop], [:coelho, :render, :stop], [:coelho, :storage, :stop]],
  &MyApp.Telemetry.handle/4,
  nil
)
```

Validation carries how big the document was and how many errors there were,
rendering how many bytes came out, storage which storage and which key. The
schema travels as a fingerprint rather than as a struct — see
`Coelho.Telemetry`. `:telemetry` is optional; without it the spans compile
down to calling the function.

Validation runs on every keystroke of every editor, so a handler on it is on
a hot path: count and summarise, do not log.

## Searching it

`to_text/2` gives a document's plain text, and a `jsonb` column is not
searchable as it stands — the text has to become a column of its own,
written when the document is. `Coelho.Document.to_text/2` carries the
migration, the changeset and the two things that follow from it being a
derivative.

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

Redeclaring an existing name **adjusts** it: what the declaration names is
taken from it, and what it leaves out is kept from the spec already there.
Giving the shipped `bold` a theme's class is a line, and it keeps the
`parse: ~w(strong b)` it was shipped with:

```elixir
marks: [bold: [class: "font-bold"]]
```

A whole declaration key is the unit — `attrs:` replaces the attribute map
rather than merging into it.

**Build it once.** A schema is a value with nothing mutable in it, and
building one costs real time: parsing every content expression, deriving the
groups and the name tables, exporting it to JSON and hashing that. Put it in
a module attribute and it is paid at compile time, once, for the life of the
release — every term in it is escapable, provided render functions are named
rather than closures:

```elixir
defmodule MyApp.RichText do
  @schema Coelho.Schema.extend(Coelho.Schema.default(), marks: [highlight: [render: {"mark", []}]])

  def schema, do: @schema
end
```

A function that calls `Schema.extend/2` on every invocation builds a fresh
schema per rendered document — measured by an application at 110 µs a call
against 2.8 µs once it was a module attribute, on a page rendering several
texts. `Coelho.Schema.default/0` is already settled that way, in
`:persistent_term`.

A `:class` on a node or mark is applied by the server renderer *and*
exported to the browser, so the writer sees the class the public page will
carry without a hook written to put it there. Declaring it twice is what
lets the two drift, so it is declared once:

```elixir
marks: [highlight: [class: "hl hl-gradient", render: {"mark", []}]]
```

`:editor_attrs` carries DOM attributes for the editor alone.

### And what the editor draws for it

A `:render` and a `:parse` that are declarations rather than functions are
exported with the schema, and the browser builds the mark's `toDOM` and
`parseDOM` out of them. The `highlight` above therefore needs no JavaScript
at all: the editor draws the same `<mark class="hl hl-gradient">` the page
does, and recognises it again on paste.

A node or mark whose rendering *is* a function has no such export, and the
browser is told so out loud — the hook logs which one, and draws a bare
`<span>` or `<div>` carrying the declared class so the document still
mounts. Give it a browser half to silence that:

```javascript
const Coelho = createCoelhoHook({
  marks: { mention: { toDOM: (mark) => ["span", { "data-user": mark.attrs.user_id }, 0] } }
});
```

## What the toolbar shows

An icon per command, drawn by `Coelho.Icons` — line drawings written for the
library, stroked in `currentColor` so they take the button's colour in every
state, and sized by the `--coelho-icon` custom property. The command's name
is the button's tooltip *and* its accessible name, so a pointer and a screen
reader are told the same thing.

Those names are English until you say otherwise, and `:labels` is where you
say it:

```heex
<.coelho_editor
  field={@form[:body]}
  labels={%{"bold" => gettext("Bold"), "bullet_list" => gettext("Bulleted list")}}
/>
```

Changing them on a mounted editor redraws the toolbar, so a language switched
mid-session reaches the buttons — and the field beside them, through
`:field_labels`.

A command the library does not draw — a mark your application added — shows
its label as text until you give it an icon:

```heex
<.coelho_editor
  field={@form[:body]}
  toolbar={~w(bold italic highlight)}
  icons={%{"highlight" => MyApp.Icons.highlight()}}
/>
```

`:icons` replaces one drawing or all of them. Each has to be safe markup
already — a `~H` sigil, `Phoenix.HTML.raw/1`, or a `{:safe, iodata}` — since
it is rendered rather than escaped. A plain string is escaped like any other
text and shows as tag soup in the button, which is the right way round:
markup is what you state, never what you happen to hold.

Yours is sized by `--coelho-icon` like the shipped ones: the stylesheet asks
for an `svg` or an `img` inside the button rather than for a class, so it
needs no `.coelho-icon` of its own.

An *attribute* can say how its own value reaches the DOM, with `:render_as`
— also applied on both sides, and also declared once:

```elixir
attrs: [
  align: [
    default: nil,
    validate: {:nullable, {:one_of, ~w(left center right justify)}},
    render_as: {:style, "text-align"}
    # render_as: {:class, %{"center" => "text-center", "right" => "text-right"}}
  ]
]
```

Alignment ships as the style, because that needs no stylesheet: the HTML
works in an email, a feed, an export. It is also what a page's own CSS
cannot override, so an application that would rather own alignment in its
stylesheet asks the shipped schema for classes and names them itself:

```elixir
Coelho.Schema.Default.build(align: {:class, %{"center" => "text-center"}})
```

Both forms are closed over the values they name. A stored document is never
re-validated on the way out, so a class map is its own allow list — a value
it does not name renders nothing — and `{:style, property}` is accepted only
on an attribute whose validator is a `{:one_of, list}`, checked again when it
renders.

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
