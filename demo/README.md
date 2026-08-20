# Coelho demo

A single page showing what storing the document instead of the HTML buys you.

Type on the left. Everything on the right is recomputed on the server, from
the stored tree, on every keystroke:

- the **rendered HTML** and its source,
- **what is actually stored** — a validated JSON document, no markup,
- **what full text search would index**,
- the **schema violations**, straight off the changeset.

The attachment in the sample document shows the other half of the argument:
its URL carries an expiry that moves on every render, because the document
stores a key and the URL is resolved each time. Storing rendered HTML would
freeze that URL in place.

Drop or paste a file into the editor and the whole attachment path runs:
the bytes go up through LiveView's upload channel into
`Coelho.Storage.Disk`, the document gets a key, and the rendered HTML on the
right carries a signed URL that `Coelho.Plug.Attachments` serves — and that
expires five minutes after each render.

## Running it

```
mix setup
mix phx.server
```

Then open http://localhost:4000.

There is **no database**. Coelho stores the document in the row that owns it,
so the demo gets away with an `embedded_schema` and a changeset — that is the
whole persistence story.

## Checking that a person can actually type in it

No Elixir test can establish that. `test/browser/editor.mjs` drives a real
Chromium against a running instance and checks the things only a browser
knows: that the editor mounts, that typing reaches the document *and* the
server, that the toolbar and the keyboard apply marks, that undo works, and
that dropping a file in stores it and serves the bytes back through a signed
URL.

```
npx playwright install chromium
PORT=4321 mix phx.server &
BASE_URL=http://localhost:4321 npm run test:browser
```

## Checking that both halves agree

The schema is declared in Elixir and exported to the browser, but `toDOM` and
`parseDOM` are functions and live in `assets/js/coelho.js`. That file is the
only place the two halves can drift. Two checks cover it:

- in the library, `test/coelho/schema_drift_test.exs` compares the names,
- here, the bridge check feeds the real exported JSON to the real browser
  code and builds an actual ProseMirror schema:

```
mix run -e 'File.write!("/tmp/coelho_schema.json", JSON.encode!(Coelho.Schema.to_json(Coelho.Schema.default())))'
mix run -e 'File.write!("/tmp/coelho_doc.json", JSON.encode!(Coelho.empty()))'
node priv/check/schema_bridge.mjs /tmp/coelho_schema.json /tmp/coelho_doc.json
```

## Notes on the setup

- npm packages are installed at the app root rather than under `assets/`, and
  `config/config.exs` adds that directory to esbuild's `NODE_PATH`. Coelho's
  hook lives outside the app and imports ProseMirror by bare specifier; Node
  resolution walks up from the *importing* file, which otherwise never
  reaches this app's `node_modules`.
- `import {Coelho} from "../../../assets/js/coelho.js"` reaches into the
  checkout above, because a path dependency is not copied into `deps/`. An
  application depending on Coelho from Hex writes
  `"../../deps/coelho/assets/js/coelho.js"`.
- daisyUI was removed from `assets/css/app.css`: the vendored build shipped by
  the generator does not accept options under Tailwind 4.1.12, and this page
  is plain CSS anyway.
