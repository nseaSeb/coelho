# Changelog

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
