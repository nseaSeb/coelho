# Contributing

The project is young and the ground is still moving, which is the good
moment to arrive: the decisions that are wrong are still cheap to change.

## Running everything

```
mix check                                                        # format, compile, credo, dialyzer, test
mix test --cover                                                 # and what nothing runs any more
docker compose -f docker/compose.yml run --rm --build browsers   # the editor, in three engines, on Linux
cd demo && mix test
```

The coverage run has a floor in `mix.exs` and fails below it. The number is
not the point — what it is for is the list of lines nothing has ever run, in
`cover/`. The first time it was measured it named several functions in
`Coelho` itself, the module every application calls first: one-line
delegates nobody had tested, because a delegate cannot go wrong. It can
point at the wrong function, take its arguments in the wrong order, or drop
an option on the way through, and the compiler is content with all three.

The Docker run matters more than it looks. Browser behaviour written on a
Mac cannot be trusted until it has run on Linux — Firefox delivers neither
`Ctrl+I` nor `Shift+Enter` to the page there, `Home` leaves the caret at the
end of the line, and `document.activeElement` is answered differently by each
engine. Several bugs in this repository were invisible until that run existed.

## What a change is expected to carry

A test that would have failed before it. Not a ceremony: nearly every defect
found here so far was found by a test that did not exist yet, and the ones
found by reading code were the shallow ones.

Where to put it:

| The change is about | The test goes in |
| --- | --- |
| the document, the schema, rendering | `test/coelho/` |
| foreign HTML | `test/coelho/html_test.exs`, and a property if the rule is general |
| the editor's behaviour in a browser | `demo/test/browser/editor.mjs` |
| the markup the component emits | `test/coelho/live_view_test.exs` |

A note on browser tests: **wait for the effect of a gesture, not for the
condition you think precedes it.** Asking the page whether the editor has
focus is answered differently by each engine; asking whether the document is
now empty is the same question everywhere. Every flaky check here started as
a wait on a precondition.

## Things worth doing

Roughly in order of how much they would help someone using this:

- **An object-storage adapter.** `Coelho.Storage` is five callbacks plus an
  optional `redirect_url/3`, which is what lets the plug hand the reader
  straight to a presigned URL instead of streaming every byte through the
  application. Nothing about S3 belongs in this library, but an adapter in
  its own package would unblock anyone not on a single machine.
- **Resizing an image.** The *size* is a schema attribute like any other
  (`Coelho.Schema.extend/2`); the *handles* are a ProseMirror node view,
  which `createCoelhoHook({nodeViews: …})` passes straight through. Both
  halves have a place to live; neither is written.
- **Tables, in the editor.** The server half ships — `Coelho.Schema.Default.build(tables: true)`
  declares four nodes, and a table validates, renders, extracts to text and
  survives an import that used to drop it. What is missing is the half that
  makes one pleasant to write: cell navigation, and the row and column
  commands. That is `prosemirror-tables`, a peer dependency this package
  does not yet declare, wired through the hook. Note what the toolbar rule
  below says about it: "a table with N columns" is not a command, so
  inserting one goes through the seam the library already has, and the row
  and column verbs are what to argue about.
- **An accessibility pass.** The toolbar is reachable by keyboard and names
  its commands, and there is one check for each — that is a floor, not an
  audit. Nobody has listened to this with a screen reader.
- **Real use.** The most valuable contribution is putting it in something and
  saying what broke.

## What may become a toolbar command

The list of node commands has been called closed twice and opened twice —
once for heading levels, once for inserting an inline void node — each time
on a good argument. A third request is coming, so here is the rule the two
openings were really applying, written down so it answers before the
argument starts.

**A command is a verb the hook can run for a whole class of schema
declarations, with no decision left to the application.**

Four questions decide it, and all four have to answer yes.

**1. Is there one verb, and only one?** A block needs a decision about what
happens to the selection and to what surrounds it, and every kind of block
needs a different one — a heading replaces the block type, a quote wraps,
a list wraps and lifts, a rule is inserted between blocks. That is why node
commands are a closed list and why a node an application adds gets no verb
with it. An inline atom is the opposite: it goes where the cursor is,
replacing the selection if there is one, and there is no second reading of
what a click should do. `inline: true, void: true` *is* the verb.

**2. Can the schema be asked whether it applies?** Every command is filtered
by asking the declaration, never a list of names kept beside it: a mark
exists; some node declares `align` and its validator accepts this value;
`heading` declares `:level` and its validator accepts this number; a node is
an inline atom and its attributes accept what the entry names. A command
whose applicability cannot be asked of the schema is a button offered where
it does nothing, or one that writes what the server then refuses — and both
lose what the writer typed.

**3. Does every value that reaches the document pass the schema's own
validator first?** Before the button is rendered, not after the click. This
is what stops the toolbar from being a second, looser way into the document
than the editor itself.

**4. Is what it does a state, or an act?** A command that turns something on
reports `aria-pressed` and reads as pressed when it is in force; a command
that *does* something — `undo`, `caption`, `insert` — reports nothing,
because there is nothing about it to be in force. Both are commands; a
command that cannot answer which it is has not been thought through.

### How it is named

A value that is scalar and closed is baked into the name — `align_center`,
`heading_3` — because the name is then the identity `:labels` and `:icons`
are keyed by, and nothing new has to be learned. A value that is open or
structured takes an entry with options — `{"insert", node: …, attrs: …}` —
and carries its own `:label` and `:icon`, because six buttons differing only
in an attribute cannot share a key.

### What will never be one

Anything that needs application state, or a decision the schema cannot
express: a menu, a picker, a modal, a suggestion list filtered as the writer
types, "a table with N columns". Those are the application's, and they have
seams rather than commands — an event the hook dispatches, a node the server
inserts through `Coelho.LiveView.insert_node/3`, a node view passed to
`createCoelhoHook`. The seam is the honest answer: it says the decision is
yours, where a command would pretend the library had made it.

Applied to the request already asked for — a character that opens a list the
application supplies, filtered as the writer types — the rule says no, and
says what instead: the list is the application's to draw and its choice is
the application's to make, and the node it settles on goes in through the
insert it already has.

## The seams

A seam is a place where a term this library did not build reaches code that
does something with it: a function an application declared in its schema, a
callback it implemented, a value it passed through the component. The list
below is all of them.

It is worth keeping because of where the defects are. Every one found in
September lived on a seam, none was caught by the suite, and the suite was
green through all of them at 93 % coverage — because a generator built from
the schema produces what the schema admits, and a seam is the one place a
term arrives that it does not. The two things that did catch them were a
review that *executed* a matrix of values, and a property.

So the question a seam answers is not "is it tested" but **"what happens
when it hands back something else"**, and the only honest way to ask that is
to hand it everything.

| Seam | The application supplies | Held to it by |
| --- | --- | --- |
| `:render`, `:render_inline` on a node or a mark | a `{tag, attrs}` tuple or a function returning iodata | a property, for the attributes only |
| `:attrs` inside a render tuple | a list of pairs, or a function of the node and the context | a property |
| `:to_text` | iodata, or a function returning it | a property |
| `:class`, `:editor_text`, `:parse` | strings the browser half also reads | the schema's own fingerprint, which refuses at build what it cannot export |
| an attribute's `:validate` | `:ok` or `{:error, message}` | nothing yet |
| an attribute's `:render_as` | `{:style, property}` or `{:class, map}` | nothing yet, though the value is checked against the ones the attribute declares |
| `Coelho.Storage` — `put/3`, `read/2`, `path/2`, `delete/2`, `exists?/2`, and the optional `redirect_url/3` and `stream/2` | the tuples each callback declares | nothing yet |
| `:resolve` in the render context | a function or a map, answering with the URL an attachment is served from | nothing yet |
| `:authorize` on the plug | `{m, f, a}` or a function of two arguments, deciding whether bytes are served | nothing yet |
| a rule passed to `Coelho.HTML.from_html/3` | a map, or a function, saying which attributes an imported element keeps | nothing yet |
| `:toolbar`, `:labels`, `:icons`, `:field_labels` | words and markup that reach the page and the exported JSON | nothing yet |
| `cast_stored` and its neighbours, overridden in the Ecto or Ash type | a document, or an error | nothing yet |
| `nodeViews`, and the `nodes` and `marks` DOM overrides, passed to `createCoelhoHook` | ProseMirror node views and DOM specs | nothing yet |
| `setPreviewUrl/2` | a URL an image is shown from until its upload lands | nothing yet |

Two of those rows are worth reading twice. `:icons` is handed to
`Phoenix.HTML.Safe`, so anything that is not safe markup raises while a page
is rendering. `:resolve` and `:authorize` decide what a reader is shown and
what a reader may fetch, which makes them the two seams where the wrong
answer is not a broken page but a wrong one.

### What a new seam owes

Two properties, and they ask different questions:

* **It answers rather than raises**, for any term at all. This is the one
  `Coelho.HTML` has carried since the import existed — "no HTML raises,
  whatever it is" — and the one the renderer went without.
* **Two paths agree.** A property of the first kind cannot see two functions
  reading one row and reaching different answers, because both of them
  answered. That is what an empty `figcaption` on a page, nothing in the
  inline form and a filename in the search index turned out to be, and only
  a review found it.

## Scope

Coelho stores and validates a document, renders it, and gets one into and out
of a browser. It does not store bytes, process images, or manage state
between two people editing at once. Those have places to plug into — a
storage, a resolver, a node view — and keeping them outside is what keeps the
part that is here small enough to be sure of.
