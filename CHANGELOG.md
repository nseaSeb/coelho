# Changelog

## 0.3.1 — 2026-08-21

### Fixed

- The third route to the shortening 0.3.0 closed twice. "Every text node in
  an inline context is collapsed" was enforced in one place that
  `wrap_inline_runs/3` never called: it built its block directly, so a run it
  wrapped reached storage exactly as it arrived. That bites when `fit/3` has
  lifted a code block out of somewhere it could not sit — the text comes up
  verbatim, is left loose among the block's children, and gets wrapped:

      <blockquote><pre>a   b</pre></blockquote>

  stored as `a   b`, rendered as `<blockquote><p>a   b</p></blockquote>`, and
  imported again as `a b`. The shipped schema cannot reach it — no node there
  admits blocks while refusing code blocks, so the lift never happens — but a
  schema of your own can. Routing the run through the same place fixes the
  other half too: lifting can leave two text nodes of the same marks side by
  side, and they belong together.

### Documented

- What `Coelho.Plug.Attachments`' `:authorize` does at its edges, none of
  which the documentation had answered and all of which the code already got
  right. It runs before `:metadata` is looked up and before
  `c:Coelho.Storage.redirect_url/3` is asked for anything, so a refusal costs
  one callback and no query. A refusal is `403` with the same body a bad
  signature gets, and deliberately not `404` — telling "this is not yours"
  apart from "this does not exist" tells the caller it exists. And it fails
  closed by failing: nothing rescues, so an exception becomes a `500` and is
  never turned into permission. A test each.

## 0.3.0 — 2026-08-21

A second adoption report, on 0.2.0. Almost all of it is the editor: 0.2.0
answered what the *document* could not do, and left the component assuming a
shape — a form, a changeset, a field — that the application reporting had
nowhere to get.

### The editor

- **`:name` and `:value`, instead of a `:field`.** The component required a
  `%Phoenix.HTML.FormField{}`, which a surface with no changeset behind it —
  a JSONB draft posted straight into `phx-change` — could only satisfy by
  fabricating one. Give it a name and a value instead.
- **`:flush_event`, for the keystrokes a debounce is still holding.** The
  editor writes into its hidden input and lets `phx-change` carry it, so a
  `phx-debounce` can still be holding the last edit when the element leaves
  the DOM: LiveView cancels the timer with the element and the change is
  lost. Cancelling a draft, switching a tab, collapsing a section — each
  removes the editor, and each was where the writer lost their last few
  characters. The hook now pushes the document on the way out, with a token
  the application chose, so a flush from before a cancellation can be
  refused rather than putting back what the cancellation threw away.
- **`:maxlength`, and a counter that is right at the first paint.** The count
  is `Coelho.Document.text_length/1`, the same unit the schema's
  `max_text_length` is checked against, and the server renders the first one
  so an existing document does not read zero until the hook has started. It
  shows; refusing is still the schema's job.
- **A schema changed under a mounted editor is now picked up.** The container
  carries `phx-update="ignore"`, which meant the node types, the marks and
  the classes they carry stayed the ones read at mount — what the writer saw
  stopped matching what the page would render. The hook follows a
  fingerprint on its own element and rebuilds the view, keeping the
  document; the toolbar is redrawn with it. Ids are untouched, so
  `editor_id/1` and `insert_node/3` are unaffected.
- **`:labels`,** because a toolbar has to speak the reader's language and the
  commands are not words.
- The flush token comes back as a **string**, since it travels as a DOM
  attribute. Comparing it to an integer generation is always false, and every
  flush is dropped by the clause meant to catch the stale ones.
- **`coelho_schema/1`,** so several editors share one copy of the exported
  schema instead of carrying 1.3 KB each.

### Testing it

- `Coelho.LiveViewTest` — `type/4` posts a document as the hook would,
  `document/2` reads back what an editor is holding, `params/3` builds the
  parameters for a test that sends them its own way. The editor's container
  is `phx-update="ignore"`, so it is invisible to `render_change/2`: every
  test touching it was encoding JSON and nesting parameters by hand.

### Serving attachments

- **`:authorize` on `Coelho.Plug.Attachments`.** A signed URL is a bearer
  token: whoever holds it, holds the file. Mounting the plug behind the
  application's authentication pipeline does not close that — it answers
  "may this person use the application", never "is this file theirs", so a
  URL minted for one organisation and replayed by a member of another passes
  both the pipeline and the signature. The callback is given the connection
  and the key, and the tenant comes from the connection: the key arrives
  from the URL, so deriving it from there would be asking the attacker which
  tenant they are in.
- **`Coelho.Attachment.generate_key/1` takes a `:prefix`,** for an
  application that backs up or purges per organisation and has no way to
  list one organisation's objects. It is an inventory aid and never an
  authorization boundary, and it says so. It belongs with object storage:
  `Coelho.Storage.Disk` shards on a key's first two characters, which a
  shared prefix makes identical for every tenant.
- **A reference S3 adapter, in `Coelho.Storage`'s documentation** rather than
  in the package: an adapter means an HTTP client and a signing library, and
  the document core has no dependencies at all. With the two things that
  bite — `put/3` must stream rather than read, and ExAws over HTTP/2 fails
  above about a megabyte with `:send_buffer_full`, which looks like a Coelho
  problem and is a transport one.

### Messages

- `Coelho.Document.Error.describe/1` takes an error apart — position counted
  from 1, scope, attribute name, mark index — for an application that has to
  word it in its own language. `humanize/1` is an English default that says
  `block 2, "href": …` instead of `content[1].marks[0].attrs.href`. Both
  changesets carry it, under `:human`, beside the machine one.

### Fixed

- `coelho_schema/1`'s JSON was rendered literally as `{@json}`: HEEx leaves
  the content of a `<script>` alone so that a JavaScript object literal
  survives it, and the curly interpolation is not interpolation there. It is
  a hidden element with a `data-` attribute now — patched like anything else,
  and with none of a script's escaping rules. Marking it `phx-update="ignore"`
  to keep LiveView off it, which the first version did, froze the one thing
  an editor reads to notice its schema moved.
- Rebuilding after a schema change no longer empties the document.
  `Node.fromJSON` is all or nothing — it throws on the first node, mark or
  attribute the new schema does not recognise — so a renamed mark used to
  take the writer's whole document with it, while the hidden input went on
  holding the old JSON. The document is re-interpreted through the DOM, which
  is ProseMirror's own lenient path: what the new schema can parse it keeps,
  what it cannot it drops.
- The link and caption field is found again after a rebuild. The toolbar's id
  carries the schema fingerprint, so a schema change makes LiveView replace
  it — and the field captured at mount was left detached, with the button
  appearing to do nothing at all.
- The HTML import shortens text no longer, the other way it could. 0.2.0
  fixed a run split across two nodes by an element the schema drops; this is
  the same defect reached from the other side. A `<pre>` keeps its whitespace
  to the character, which is what a code block is for — but a code block that
  cannot sit where it landed is lifted, and its text arrives verbatim in a
  paragraph, where nothing keeps it. Stored like that, the next import
  collapses it. Every text node in an inline context is collapsed now, whole;
  a node that takes its text verbatim never reaches that path at all. Found
  by CI, on a seed 120 local seeds had not drawn.
- The flush's failure guard catches the failure it was written for.
  `pushEvent` rejects a promise rather than throwing when the socket has
  gone, so the `try/catch` never ran and a page navigation logged an uncaught
  error instead of a warning.

## 0.2.0 — 2026-08-21

Everything here answers a report from an application that tried to adopt
0.1.0 and listed what stopped it. The theme is that 0.1.0 covered the path
from the editor to the database, and left the paths *out* of it — to a
renderer that is not HTML, to a proof of what was accepted, to a page served
from a row nobody re-checked — to the application.

### Breaking

- `Coelho.from_html/2` and `Coelho.HTML.from_html/2` now answer
  `{:ok, document, warnings}` rather than `{:ok, document}`. The import is
  lenient by design, and staying silent about what it dropped meant an
  imported document lost its tables and the person who pasted it found out
  from a reader.
- An attribute left at its schema default is no longer written into the
  document. Two editors that disagreed on whether to send `align: "left"`
  stored different documents for the same text, which made a digest of the
  document worth nothing — and the absent key is also what stops a plain
  paragraph from carrying an `"attrs"` object. Renderers reading attributes
  directly should read them through `Coelho.Render.attr/3`, which takes the
  schema default.
- Marks are sorted into the schema's declaration order, which is what
  ProseMirror ranks them by. `["bold", "link"]` and `["link", "bold"]`
  describe the same fragment and now normalise to the same document.
- Every schema carries `:limits` — 10 000 nodes, 100 levels, 1 000 000
  characters unless it says otherwise. Nothing bounded the size of a document
  arriving in a hidden form field before. `limits: [max_nodes: :infinity]`
  lifts a bound deliberately.

### Rendering somewhere other than a web page

- `Coelho.Render.reduce/4` folds a document into any term at all, through a
  `:node` and a `:text` callback, where `:text` is handed the marks resolved
  against the schema in a stable order. The result is not constrained to
  iodata, so a target with its own escaping — a typesetting language, a
  search index — gets a tree of plain terms and lets its own encoder do the
  quoting. `Coelho.reduce/4` is the same thing over the shipped schema.
- `Coelho.Render.attr/3` reads an attribute with its schema default in hand.

### Proving what was accepted

- `Coelho.Document.canonical/1` serialises a validated document byte for
  byte the same however its keys are ordered — which a plain JSON encoding
  cannot promise, since `jsonb` reorders keys on its own.
- `Coelho.Document.hash/2` is its digest, `nil` for a document holding
  nothing. Hash a *validated* document: a digest taken on the value read back
  from the database answers a different question.

### The way out of storage

- `Coelho.Document.sanitize/2` turns any term into a document the schema
  accepts, without failing and without reporting. Stored documents are not
  re-validated on load, so a row written under a looser schema or by a direct
  SQL write reached a public page unchecked. A hostile document becomes a
  poor document: a `javascript:` link becomes plain text, a heading claiming
  level 99 becomes a level 1 heading, an unknown node goes.

### Ash

- `Coelho.Ash.Type`, a `use` rather than a ready-made module, because Coelho
  does not depend on Ash — not even optionally: Ash depends on `:stream_data`
  in every environment and Coelho keeps it to `:dev` and `:test`. One module
  in your application, and the schema arrives as a constraint. Failures
  surface as `Ash.Error.Changes.InvalidAttribute` with the location in the
  document tree in `vars`, so a form can say more than "is invalid".

### Schemas

- `Coelho.Schema.restrict/2` narrows a schema by subtraction. Six fields with
  six different vocabularies were six full schemas to keep consistent by
  hand; a restricted schema cannot accept what its parent rejects.
- `:class` and `:editor_attrs` on a node or mark spec. The class is applied
  by the server renderer *and* exported to the browser, so the writer sees
  the class the public page will carry, declared once.
- `paragraph`, `heading` and `list_item` in the shipped schema carry an
  `align` attribute — `left`, `center`, `right`, `justify` — rendered as a
  `text-align` style and read back on import.
- A schema may declare a `:version`. `validate/2` stamps it and refuses a
  document stamped differently, and `Coelho.migrate/2` is the deliberate move
  between two versions.

### Counting

- `Coelho.Document.text_length/1`, and `textLength` in the browser half,
  count the same thing: the text nodes concatenated, no bullets and no blank
  lines. A counter measured on `to_text/2` rejects a document the editor
  still shows as under the limit, with nothing on screen to explain the gap.

### Fixed

- The HTML import no longer shortens text a space at a time. Whitespace is
  collapsed per text node, and an element the schema does not know is
  transparent — so `a   <a>   b</a>` with no `href` arrived as two nodes that
  had each kept one space, and storing them side by side stored two.
  Importing what that rendered to collapsed the pair back to one, so a round
  trip through storage kept rewriting people's documents. A run of text is
  now made whole before it is stored and collapsed as the one run it is,
  never joined across a mark — the space inside an emphasis is emphasised.

  This was what made the round-trip property fail on roughly one seed in
  twelve.

### Also

- An unknown mark is now named in the error rather than reported as
  `missing or unknown "type"`.
- An unknown *attribute* is reported at its own key —
  `content[0].attrs.onclick` rather than `content[0].attrs`. The path is what
  `sanitize/2` repairs from, and an error at `attrs` took every attribute on
  the node with it, so one stray key cost a heading its level.
- `Coelho.Document.Error.format_path/1` is public.

## 0.1.0

First release. Everything below is new, so the list is what the library
does rather than what changed.

### The document

- `Coelho.Schema` — nodes, marks, content expressions, attribute validators.
  `extend/2` adds to the schema that ships rather than replacing it, and
  `to_json/1` exports it for the browser, ordered, because ProseMirror
  resolves default types by position.
- `Coelho.Document` — `validate/2` is the sanitisation: an unknown node,
  mark or attribute rejects the document, so nothing outside the schema
  reaches the database. It also normalises — attribute defaults filled,
  marks deduplicated, adjacent text runs merged — so what is stored is
  canonical. Nesting past 100 levels is refused, error paths and sibling
  errors accumulate linearly, and the strings kept are copied so a document
  does not pin the payload it was parsed from.
- `Coelho.Render` — HTML from the document, overridable per node and per
  mark, with a `:context` for what only the application knows.

### Storing it

- `Coelho.Ecto.rich_text/2` and a parameterized Ecto type that validates on
  cast, attaching the schema violations to the changeset. Documents already
  in the database are not re-validated on load.
- Inline in a `:map` column on the table that owns it. No side table, no
  join.

### Editing it

- `Coelho.LiveView.coelho_editor/1` — the editor as a function component.
  The document travels through a hidden input, so it is an ordinary form
  field. The toolbar says what is in force and disables what cannot run;
  links and captions are edited in a field beside it.
- `assets/js/coelho.js` — the browser half, built on ProseMirror. Images
  pasted from other sites are fetched and stored rather than hotlinked.

### Attachments

- `Coelho.Attachment` and `mix coelho.gen.migration` for the metadata,
  `Coelho.Storage` for the bytes, with a local-filesystem implementation.
- `Coelho.Attachments.signed_url/4` and `Coelho.Plug.Attachments` — the
  document stores a key, never a URL, and the URL is signed and expiring.
  Only a short list of image types is served inline; everything else,
  SVG included, is sent as a download.
- `Coelho.Attachments.orphans/3` and `sweep/4` for the bytes no document
  refers to any more.

### Coming from HTML

- `Coelho.HTML.from_html/2` — the migration path for content already stored
  as markup. Unknown elements are transparent, `<script>` and friends are
  dropped with their content, and an element whose attributes fail the
  schema is treated as unknown, so a `javascript:` link loses the link and
  keeps the text.

### Known gaps

- No tables, and no image resizing.
- Only a local-filesystem storage ships; object storage means implementing
  four callbacks.
- Composition (IME) is checked committing and surviving a round trip, but
  not with a server echo landing mid-composition.
- Real-time collaboration is out of scope for now.
