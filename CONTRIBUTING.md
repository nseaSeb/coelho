# Contributing

The project is young and the ground is still moving, which is the good
moment to arrive: the decisions that are wrong are still cheap to change.

## Running everything

```
mix check                                                        # format, compile, credo, dialyzer, test
docker compose -f docker/compose.yml run --rm --build browsers   # the editor, in three engines, on Linux
cd demo && mix test
```

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
- **Tables.** The largest missing feature, and the one that decides whether
  this is usable for documentation rather than only for articles.
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

## Scope

Coelho stores and validates a document, renders it, and gets one into and out
of a browser. It does not store bytes, process images, or manage state
between two people editing at once. Those have places to plug into — a
storage, a resolver, a node view — and keeping them outside is what keeps the
part that is here small enough to be sure of.
