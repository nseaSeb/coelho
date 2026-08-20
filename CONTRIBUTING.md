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

## Scope

Coelho stores and validates a document, renders it, and gets one into and out
of a browser. It does not store bytes, process images, or manage state
between two people editing at once. Those have places to plug into — a
storage, a resolver, a node view — and keeping them outside is what keeps the
part that is here small enough to be sure of.
