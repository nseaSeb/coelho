# Changelog

## 0.8.0 — 2026-08-22

The other half of 0.6.0. A mark an application added could be stored,
validated and rendered, and 0.6.0 gave it a toolbar button — but nothing
drew it in the editor, and a schema ProseMirror cannot draw is a schema no
document can be *mounted* on. The editor came up empty, accepted typing,
never read the stored document back, never counted, never emitted a change,
and said nothing anywhere. Reported by the same application, after a day of
eliminating eight other explanations first.

The thread through all of it: the server half was closed and explicit —
strict validation, argued refusals — and the browser half was permissively
silent. Both halves now answer the same way.

### A mark of the schema draws itself

- `:render` and `:parse` are exported with the schema when they are
  declarations rather than functions, as `renderDOM` and `parseDOM`. The
  browser builds `toDOM` and `parseDOM` out of them, so
  `highlight: [class: "hl", render: {"mark", []}]` draws in the editor
  exactly as it renders on the page, with no JavaScript written for it at
  all. This is what `render_as: {:class, …}` did for an attribute, done for
  the element.
- A node or mark the browser still has no rendering for — one whose
  `:render` is a function, which only Elixir can run — is **named** at
  mount, and drawn as a bare `<span>` or `<div>` carrying whatever class the
  schema declared. The document mounts, the editor works, and the console
  says which name to give `createCoelhoHook({marks: …})`. It used to be a
  dead editor and no message.
- The class and `editor_attrs` a spec declares are no longer dropped in
  silence for want of a `toDOM`. Nothing but the text node and the top node
  can reach that case now, and either one says so.
- A stored document the schema cannot mount logs the error that made it
  impossible before falling back to an empty editor. Swallowing it was what
  turned a schema bug into an afternoon of bisecting: the message names the
  node, mark or attribute that is missing, which is the whole answer.

### A bound cuts to fit rather than emptying

- `Coelho.Document.sanitize/2` answered a document over `:max_text_length`
  or `:max_nodes` with an *empty* document. The mechanism was understandable
  — a bound is reported at the root, and the only repair at the root is
  replacing the root — and the effect was not: terms and conditions five
  hundred characters over a bound came back as nothing at all, and the
  application's own length guard, measuring what came back, then saw zero
  and had nothing to say. Text is now truncated at the bound and nodes are
  cut off at it, which is the repair that loses least.
- `:max_depth` emptied the document too, and for the same reason: what is
  nested too deep was *replaced* with an empty node rather than removed, so
  the bound went on refusing it. One bullet indented a level too far took
  every paragraph beside it. It is dropped now, and what cannot stand
  without it — a list item with nothing left in it — goes the way any node
  whose content no longer satisfies its expression goes.
- `sanitize/3` takes `:limits`, which override the schema's for that call.
  A bound is a bound on *writing* — the browser posts into a hidden field no
  `maxlength` constrains — and reading is a different question:
  `limits: [max_text_length: :infinity]` cleans the structure and leaves the
  length for the application to judge, with the whole document in hand to
  judge it on. It replaces keeping a second schema per field to sanitise
  against.

### `Schema.extend/2` adjusts a name rather than replacing it

- Redeclaring an existing node or mark now keeps what the declaration does
  not mention. Giving the shipped `bold` a theme's class was a line that
  silently took its `parse: ~w(strong b)` with it, so a `<strong>` pasted
  out of a word processor came in as plain text — found by a code review,
  not by a test. A whole declaration key is still the unit: `attrs:`
  replaces the attribute map rather than merging into it, because an
  override that can only add is not an override.

### The stylesheet

- `--coelho-max-height` (default `none`) and `--coelho-height` (default
  `auto`). An editor that grows with its text pushes the buttons that save
  it off the bottom of the screen, and several thousand characters of terms
  and conditions is exactly that.
- The editor's own rule sets `color` beside the `background` it already set.
  Half a pair is worse than neither: an application giving
  `--coelho-surface` its own theme's colour got the page's text colour on
  it, which is how a field holding a thousand words comes to look empty.
- `data-coelho-theme` is documented, takes `dark` as well as `light`, and
  now opts out of the automatic dark palette whatever its value. The palette
  has to be all or nothing: a property set on the element beats one the
  element merely inherited, whatever either one's specificity, so an
  application declaring its own tokens further up the page got its surface
  and our text — light on light, and a field that looks blank. Weakening the
  selector only moves which half is lost; one attribute settles it.

## 0.7.0 — 2026-08-22

### The toolbar draws

- An icon per command, from the new `Coelho.Icons` — line drawings written
  for the library rather than taken from an icon set, so there is nothing to
  attribute and no second visual identity arriving with the dependency. They
  are stroked in `currentColor`, so they take the button's colour in every
  state the stylesheet already draws, and sized by a new `--coelho-icon`
  custom property.
- The command's name is now the button's `title` *and* its `aria-label`, so
  a pointer and a screen reader are told the same thing. It used to be the
  button's visible text.
- Those names are English by default, like the field's own words and for the
  same reason: a tooltip reading `bullet_list` is worse than no tooltip.
  `:labels` still overrides them, still redraws the toolbar when it changes,
  and still reaches the field beside it through `:field_labels` — the
  translation path did not need anything new.
- `:icons` replaces one drawing or all of them. A command the library does
  not draw — a mark an application added — shows its label as text, which is
  what it did before an icon existed.

## 0.6.0 — 2026-08-21

The third layer. A formatting exists end to end when the schema can carry
it, the renderer can show it, and a toolbar button can set it — and the
third was closed over a hard-coded list. Reported by an application whose
own marks were stored, validated, rendered, and invisible.

### Any mark of the schema is a button

- The toolbar's mark list (`bold italic strike code link`) is gone from both
  halves. A mark always toggles the same way, so a mark added with
  `Schema.extend/2` — a highlight, an effect — gets its button without the
  application writing a line of JavaScript. `link` keeps its own case, which
  opens the field.
- Node commands stay a closed list, deliberately: each kind of node takes
  its own verb in the hook — toggle a block, wrap, list — and a node added
  to a schema gets no verb with it. The server now filters against that
  list, so a custom node's button is dropped rather than rendered inert.
- A button the hook has no command for is greyed out. `Boolean(command) &&
  !command(…)` read as "enabled" precisely when there was no command — the
  one case the guard was for.
- `aria-pressed` is *removed* when a command has no state to report, rather
  than left as it was. A button that stays in the toolbar while its answer
  turns to "no state" — an alignment button once the selection leaves every
  alignable block — went on announcing pressed to a screen reader about a
  block that was no longer there.

### Alignment has commands

- `align_left`, `align_center`, `align_right`, `align_justify`. The `align`
  attribute was declared, rendered and read back since 0.2, but nothing
  could set it: it existed only where an import had carried it in. Not in
  the default toolbar — name them to show them.
- The toggle is decided once for the whole selection, like a mark button:
  everything already carries the value, the click removes it everywhere;
  otherwise it applies it everywhere. Per-node would center some blocks and
  uncenter others in the same click.
- Only the outermost alignable block takes the attribute — a `list_item`
  and its `paragraph` both declare it, and writing both would nest two
  `text-align`s and put a redundant attribute into the canonical
  serialization, so into `Coelho.hash/2`.
- Aligning left clears the attribute rather than writing `"left"`. The two
  look the same, and a hash used as proof of acceptance must not tell apart
  documents that differ only in which buttons the writer happened to click.
  An explicit `"left"`, which only import produces, is read as the same
  alignment as none throughout: `align_left` on such a block reads pressed
  *and* offers nothing to do, instead of a click that would change only the
  hash. A command that finds nothing to change dispatches nothing at all —
  an empty transaction still rewrites the hidden input with ProseMirror's
  serialization, which is not the server's canonical form, and WebKit lost
  the race with the server's echo where Chromium happened to win it.
- The server keeps an `align_*` button by asking the attribute's own
  validator, so a schema that narrows the alignments filters its buttons by
  itself — for the four standard values only, which are the four the hook
  has a command for. Matching the prefix alone took names from the marks:
  `align_terms` would have been dropped though the hook would toggle it,
  and a node declaring `align` with no validator (`Attr.validate(nil, _)`
  is `:ok`) would have rendered `align_middle` as a button with no command.

### An attribute can say how it renders

- `:render_as` on an attribute spec — `{:style, property}` or
  `{:class, %{value => class}}`. Data rather than a render function, so the
  server applies it *and* the exported schema carries it to the browser: the
  editor shows what the page will carry, and an application changes it in
  one place without writing any JavaScript. It is the mechanism `:class` on
  a node already was, for a class the *value* decides.
- `Coelho.Schema.Default.build/1` takes `:align`, so switching the shipped
  alignment to classes is one line rather than three redeclared blocks —
  `Schema.extend/2` replaces a node's declaration rather than completing it,
  and restating `paragraph`, `heading` and `list_item` to change one
  attribute is the friction this exists to remove.

      Coelho.Schema.Default.build(align: {:class, %{"center" => "text-center"}})

- The default is `{:style, "text-align"}`, so nothing moves: the shipped
  output is byte for byte what it was, which is what the parity tests
  assert. The style is what ships because it needs no stylesheet — the HTML
  works in an email, a feed, an export — and it is also what a page's own CSS
  cannot answer, which is why the other form now exists.
- Both forms are closed over the values they name, because
  `Coelho.Ecto.Type` does not re-validate a stored document and every
  renderer is therefore a security boundary. A class map is its own allow
  list. `{:style, property}` has none of its own, so it is refused at schema
  build time on an attribute whose validator is not a `{:one_of, list}`, and
  the value is checked against that list again when it renders.
- A node's `:render` may name its tag with a function of the node, which is
  what `heading` now does. It was a render function — building its whole
  element, and so reaching neither the spec's `:class` nor its attributes'
  `:render_as` — only because its tag is what its level decides. Three
  hand-written alignment paths go with it, one in each half.
### The installer, twice

- The stylesheet's `@import` goes right after the last `@import`, as the
  doc always said — not after the last at-rule of a preamble that counted
  Tailwind's. In a Phoenix 1.8 `app.css` the last `@custom-variant` sits two
  hundred lines in, past `@plugin` blocks and rules, where CSS drops a late
  `@import` silently.
- `mix coelho.install` now diagnoses the esbuild config: bare
  `prosemirror-*` imports resolve from `deps/coelho/`, which never reaches
  `assets/node_modules` on its own, and the first build failed with
  `Could not resolve "prosemirror-keymap"` and no pointer to the cause. The
  task never edits `config/config.exs` — the profile is the application's
  own — it says which path to add to `NODE_PATH`, as a list entry, keeping
  `Mix.Project.build_path()` and the rest of what is there.
  It names every profile that is short rather than clearing the lot on the
  first one that is covered — which profile bundles `app.js` is not
  something to guess at, and "another profile has it" is the all-clear that
  hides the failure the step exists for. It reads `env` as a map or as a
  keyword list, both of which esbuild accepts, and resolves a relative
  `NODE_PATH` entry from the profile's `cd:`, as esbuild does.


## 0.5.0 — 2026-08-21

The three things left after 0.4.0, all of them.

### Rendering inside a paragraph

- `Coelho.to_inline_html/3`, `to_safe_inline_html/3` and `to_inline_iodata/3`.
  A `<p>` inside a `<p>` is not nested by the browser, it is closed by it —
  so a document rendered into a banner, a map bubble or a card excerpt ended
  the enclosing paragraph where its own first one began, stopped every class
  on it from applying, left an empty paragraph behind, and ran the words of
  two paragraphs together where the tags that separated them had been. The
  last is the one nobody sees, because it looks like text.

  It was doable with render overrides and nobody would have got it right:
  overriding `paragraph` to render nothing gives `un grasdeux` — two words
  fused — and still emits the `<h2>` and the `<ul>`.

  The guarantee is one sentence, which is also what makes it testable in one
  assertion rather than thirty cases: **the output holds nothing that is
  illegal in an inline context.** Everything else follows without a judgement
  call — marks stay, `<img>` and `<br>` stay, every block is unwrapped to its
  children, and a node with no inline form contributes nothing.

- `:render_inline` on a node spec, for a node whose block-ness lives inside a
  render function rather than in the tree. The attachment is the case: it is
  `void: true`, so unwrapping it towards its children gives nothing, and
  contributing nothing would have `blank?/2` answer "there is something here"
  about a document that then rendered as empty — two functions of the same
  library contradicting each other about the same document.

- The separator belongs to the caller, because only the caller knows whether
  its container can take a line break. `:space` by default: a space where a
  break was wanted puts two sentences on one line, which reads, while a break
  where a space was wanted grows the caller's box and breaks their layout. A
  separator of your own is escaped unless it is `{:safe, iodata}`, since a
  value that reached it from data would otherwise be markup.

### Installing it

- `mix coelho.install`, the last of the three things left after 0.4.0 and the
  one that decides whether anyone tries the library on a Sunday. It installs
  the browser packages, imports the hook into `assets/js/app.js` and adds it
  to the LiveSocket, imports the stylesheet into `assets/css/app.css`, and
  runs the attachments migration.

  It is idempotent, it asks before running `npm`, `--dry-run` reports without
  writing, and it says what to do rather than guessing when an `app.js` is
  not shaped the way it expects — an application's `app.js` is its own, and
  an unfamiliar LiveSocket is not a reason to rewrite it badly.

  The package list comes from Coelho's own `peerDependencies`, read when the
  task compiles, so it cannot drift from what the hook imports.

### What the field says

- `:field_labels` on `coelho_editor/1`. `"Link address"`, `"https://…"`,
  `"Caption"` and `"Describe this attachment"` were hard-coded English in the
  JavaScript, and `:labels` covers only the toolbar's commands. And there was
  no hint under the field at all — the gesture that removes a link, emptying
  the field, was something a writer had to be told or discover.
- Both are in the toolbar's fingerprint and not the schema's, so a language
  switched mid-session redraws the words without costing the writer their
  undo history.

### Fixed

- A language switched mid-session reaches the field, which is what the whole
  arrangement was for. The hook read `:field_labels` once at mount and never
  again, so the buttons changed and the link field kept the words it was born
  with until a full remount — and every line of documentation saying
  otherwise was wrong. Re-read when the toolbar's fingerprint moves, and when
  the editor is rebuilt.
- The hint is announced, not only drawn. It carries an id and the input
  points `aria-describedby` at it while it is shown: a hint exists for the
  writer who has not been told the gesture, which is first of all the writer
  who cannot see it.
- `""` is an answer. An application passing an empty string for one of the
  field's words meant "say nothing here", and fell back to the English
  instead.
- Inline rendering honours a caller's `:nodes` override, including for the
  `text` node — the block renderer goes out of its way not to short circuit
  there so that no node is the one nobody can reach, and the inline one
  advertised the same options while quietly ignoring them.
- `:render_inline` is reached for an inline node too. It was checked after
  `:inline`, so the one escape hatch for an inline-grouped node whose
  ordinary render is a block-ish wrapper did nothing at all.
- An attachment with no filename no longer vanishes from an inline render.
  `filename` accepts `""` and so does `key`, and a contribution of nothing is
  dropped when blocks are joined — out of a document `blank?/2` calls
  non-blank, which is the contradiction `:render_inline` exists to avoid. It
  always renders an element now, with the classes the page and the editor
  already use.
- `mix coelho.install` finds where a statement *ends* rather than where a
  line matches, in both files it edits. `import {\n  LiveSocket\n} from "…"`
  has `import {` as its last line matching `import`, so the hook went into
  the middle of it — a syntax error in the file the whole bundle is built
  from. `@plugin "…" { … }` spans lines the same way, so the stylesheet went
  inside the block — invalid CSS. Both on the first run of the command that
  exists to make the first ten minutes work, and neither shape is exotic:
  `coelho.js` itself uses multi-line imports.
- Inline rendering honours a caller's `:nodes` override for a block too, not
  only for text and inline nodes. Overriding `attachment` is the natural
  thing for an application resolving its own URLs, and it was being ignored.
- An attachment that resolves keeps its link inline. `<a>` is legal in an
  inline context, so there was no reason to drop the href — a card excerpt
  lost the download entirely.
- An empty caption adds nothing rather than a trailing space, which the join
  then followed with a separator.
- `to_inline_iodata/3` emits the render span, so a new public render path is
  not invisible to a handler the README tells applications to attach.
- `mix coelho.install` checks the version a package is declared at, not only
  its name. An application pinned to an older `prosemirror-view` was told
  everything was there and failed inside `coelho.js`, a long way from the
  cause.
- `mix coelho.install` reports a failed `npm install` as a failure. The exit
  status was discarded, so a run with no network told the reader the editor
  would render with none of its packages present.
- And its `--dry-run` no longer offers to generate a migration that is
  already there.

### Also

- The document generators are shared between the properties rather than
  copied into each — which immediately widened what the older ones see, and
  showed that "plain text extraction only ever yields text the document
  holds" had always been narrower than its name: a node with a `:to_text` in
  its spec contributes something the document does not hold as a text node,
  which is exactly what that field is for.

## 0.4.0 — 2026-08-21

A third adoption report, on 0.3.1, and the theme this time is the distance
between "it works" and "you can pick it up". Most of it is things that were
there and unsaid, or there and left to the caller.

### The last link in the rendering argument

- `Coelho.to_safe_html/3` answers `{:safe, iodata}`. `to_html/3` answers a
  `String.t()`, which a template treats as text — correctly, since it cannot
  know it is markup — so the caller had to remember `raw/1`, with two ways to
  get it wrong: forget it and the reader is shown the source of their own
  document; reach for it elsewhere and something that should have been
  escaped no longer is. For a package whose argument is that rendering is
  safe by construction, that was the last link left to the caller. It costs
  no dependency: `{:safe, iodata}` is what `Phoenix.HTML.Engine` unwraps
  directly. There is no `Phoenix.HTML.Safe` implementation because there is
  nothing to implement it *for* — a document is a bare map, deliberately, and
  an implementation for `Map` would apply to every map in the application.

### Asking whether there is anything there

- `Coelho.blank?/2`. An application deciding whether to render a block at all
  had only `empty/1`, which *builds* an empty document, and the obvious
  stand-in `text_length(document) == 0` is wrong in the direction that loses
  content: a document holding one image, or one attachment, has no text and
  is very much not blank. This asks the schema — a node it declares
  `void: true` renders an element of its own and counts.

### Ash

- `cast_atomic/2`, explicitly. The inherited default refused an expression
  with a message about the type not supporting atomic updates, which is true
  and no help. A document is validated by walking its tree in Elixir, and
  none of that can be handed to the database, so this is not a gap to close
  later: the reason now says so and says what to do instead. A literal
  document still goes through, validated like any other cast.
- What the type does about storage and tenants, in one place where an Ash
  user will look for it: nothing to configure, `jsonb` in the row that owns
  it, no interaction with AshPostgres multitenancy — and the rule that a
  key never decides whose a file is, repeated where it is needed rather than
  only in the plug's documentation.

### Ready to use

- **A starter stylesheet**, at `assets/css/coelho.css`. Structure, states and
  the things a person needs to see — focus, which commands are in force, a
  counter gone over — with no identity of its own: every colour, radius and
  space is a custom property with a neutral default. The demo imports it and
  overrides two properties, which is now the whole of its editor styling;
  hand-writing them there meant the stylesheet nobody had to write was also
  the stylesheet nobody was running.
- **The keyboard, written down.** It was all bound and none of it was
  documented, which for a ready-to-use editor is part of the contract.
- **`Coelho.Telemetry`** — spans around validation, rendering and storage, in
  the usual `:start`/`:stop`/`:exception` shape. `:telemetry` is optional and
  the spans compile down to calling the function without it. The schema
  travels as a fingerprint, because a schema in the metadata of every
  keystroke's validation would hand every handler a copy of it.
- **How to make a document searchable**, on `Coelho.Document.to_text/2`: a
  `jsonb` column is not searchable as it stands, so the text has to become a
  column of its own, written when the document is. With the migration, the
  changeset, and the two things that follow from it being a derivative.

### Fixed

- Telemetry costs nothing where nothing is listening. The first cut built its
  metadata as an ordinary argument, so exporting and hashing the schema —
  6.4 µs — plus two walks of the document ran on every validate and every
  render whether `:telemetry` was loaded or not, which is the measurement
  costing more than the work on a path documented as running per keystroke.
  The metadata and the measurements are functions now and a build without
  `:telemetry` calls neither; the schema's fingerprint is settled once when
  the schema is built (`Coelho.Schema.fingerprint/1`); and the node and
  character counts come from the bounds check validation runs anyway rather
  than from walks of their own. Measured back down from 71 to 59 µs per
  validate.
- `Coelho.Ash.Type`'s `cast_atomic/2` answers `{:ok, …}` for a literal
  document, which is what Ash's own default answers. `{:atomic, …}` puts the
  value straight into the changeset's atomics, past the `allow_nil?` and
  required-attribute checks — and `nil` is a value this type casts, so the
  difference was a document that could be nulled on an attribute declaring it
  may not be. Unreachable through Ash today, which short-circuits literals,
  and reachable the moment a type defines `handle_change/3`.
- And it routes through the type's own `cast_input/2`, so a module overriding
  it — which `defoverridable` invites — keeps the override on this path too.
- `blank?/2` no longer counts a hard break as content. An inline void node
  declaring no attributes is punctuation, and a pasted-then-emptied field
  usually leaves behind a paragraph holding exactly one — which would have
  rendered a heading with nothing under it, the failure the function exists
  to prevent.
- `nil` renders as nothing rather than raising. It is what a nullable column
  holds and what both stored types cast an absent document to, so the
  one-liner this release recommends would have taken the page down on it.
- The editor draws an attachment the way the page does: the same classes, and
  the caption as a `figcaption` rather than not at all. A captioned
  attachment looked materially different while it was being written.
- Changing `:labels` on a mounted editor redraws the toolbar. The fingerprint
  the toolbar's id carries covered the schema and the commands but not their
  words, so a language switched mid-session changed nothing on screen — and
  the editor now carries two fingerprints rather than one, because they cost
  very different things. The schema's makes the hook rebuild the editor,
  which re-parses the document and starts a fresh undo history; the
  toolbar's only redraws the buttons. Folding the labels into a single
  fingerprint would have made a changed word throw away the writer's undo
  stack and move their caret.
- The component's documentation still said the button list was fixed once
  rendered, which stopped being true in 0.3.0 when the fingerprint went in —
  and was read, reasonably, as the behaviour.
- The demo's hand-written styles gave `.coelho-link` a `display`, which beat
  the browser's own rule for `[hidden]` — so the link field was never
  actually hidden, and the browser check that fills it was filling a field
  permanently on screen rather than one the toolbar had opened. Importing the
  shipped stylesheet made `hidden` mean hidden and the check started failing,
  which is the check finally doing its job.
- And with it, a fragility in the browser harness: it pressed select-all in
  the same breath as the click that focused the editor, which sends the press
  before ProseMirror has put its selection where the click asked. It selected
  nothing, silently, and what failed was whatever needed the selection three
  lines later. Only visible once the shipped stylesheet gave the editable its
  own height — clicks then land in the empty space below the text rather than
  on it, which is what a tall editor is mostly made of.

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
