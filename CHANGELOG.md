# Changelog

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
