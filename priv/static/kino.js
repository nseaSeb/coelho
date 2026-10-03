// Coelho in Livebook. `Coelho.Kino` renders the editor on the server, with the
// same component a LiveView uses, and this mounts the shipped hook on it
// through the four things the hook asks of LiveView: its element, pushEvent,
// handleEvent and upload. Nothing in coelho.js knows it is not in a LiveView.
//
// Shipped as priv/static/kino.js beside the bundle, which is why it imports
// "./coelho.esm.js": bundle/build.mjs copies it there and checks the copy.
import { createCoelhoHook } from "./coelho.esm.js";

// How long the editor waits after a keystroke before the document goes to
// the server, so that typing a word is one round trip rather than one per
// letter.
const SETTLE_MS = 120;

export async function init(ctx, { html }) {
  await ctx.importCSS("coelho.css");

  ctx.root.innerHTML = html;

  const el = ctx.root.querySelector('[phx-hook="Coelho"]');
  const input = ctx.root.querySelector(`#${CSS.escape(el.dataset.coelhoInput)}`);

  const hook = {
    ...createCoelhoHook(),
    el,
    pushEvent: (event, payload) => ctx.pushEvent("hook", { event, payload }),
    handleEvent: (event, callback) => ctx.handleEvent(event, callback),
    // Uploads need a LiveView's upload channel; the editor offers none here,
    // since Coelho.Kino renders it without an upload config.
    upload: () => {}
  };

  hook.mounted();

  // The hook writes every change into its hidden input and announces it with
  // an input event, which is what phx-change listens to in a LiveView.
  let settling = null;

  input.addEventListener("input", () => {
    clearTimeout(settling);
    settling = setTimeout(() => ctx.pushEvent("change", input.value), SETTLE_MS);
  });

  // A document from the server: one set from Elixir, or the last valid one
  // when the server refused what this editor sent. The hook reads its input
  // in updated() and ignores a value it wrote itself.
  ctx.handleEvent("set", (value) => {
    input.value = value;
    hook.updated();
  });
}
