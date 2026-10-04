// The entry of priv/static/coelho.esm.js: everything coelho.js exports, and
// the ProseMirror modules it was built with.
//
// The re-exports are what an application's own code imports when it touches
// ProseMirror — a node view reaching for NodeSelection, a plugin of its own.
// It must get them from here: a second copy of prosemirror-model from npm is
// a second set of classes, and every `instanceof` across the two is false.
// An application uses this bundle or the npm packages, never both.
export * from "../assets/js/coelho.js";
export { default } from "../assets/js/coelho.js";

export * as model from "prosemirror-model";
export * as state from "prosemirror-state";
export * as view from "prosemirror-view";
export * as transform from "prosemirror-transform";
export * as commands from "prosemirror-commands";
export * as keymap from "prosemirror-keymap";
export * as history from "prosemirror-history";
export * as inputrules from "prosemirror-inputrules";
export * as schemaList from "prosemirror-schema-list";
export * as tables from "prosemirror-tables";
