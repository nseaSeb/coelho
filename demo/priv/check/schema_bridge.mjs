// Proves the two halves actually fit: the schema JSON Elixir exports is fed
// to the same code the browser runs, and must build a valid ProseMirror
// schema that can parse a real document. The Elixir-side drift test compares
// names; this one compares behaviour.
import { readFileSync } from "node:fs";
import { Node as PMNode } from "prosemirror-model";
import { buildSchema, filenameFor, srcOf } from "../../../assets/js/coelho.js";

const [schemaPath, documentPath] = process.argv.slice(2);
const exported = JSON.parse(readFileSync(schemaPath, "utf8"));
const schema = buildSchema(exported);

const names = Object.keys(schema.nodes).sort();
const expected = exported.nodes.map(([name]) => name).sort();

if (JSON.stringify(names) !== JSON.stringify(expected)) {
  console.error("node mismatch", { names, expected });
  process.exit(1);
}

const doc = PMNode.fromJSON(schema, JSON.parse(readFileSync(documentPath, "utf8")));
doc.check();

// Pure helpers of the browser half, checkable without a browser. The name
// below reaches the server as an upload's client name, and applications build
// paths out of those.
for (const [url, type, expected] of [
  ["https://host/photo.png", "image/png", "photo.png"],
  ["https://host/photo?fmt=png", "image/png", "photo.png"],
  ["https://host/", "image/webp", "pasted.webp"]
]) {
  const actual = filenameFor(url, { type });
  if (actual !== expected) {
    console.error(`filenameFor(${url}) gave ${actual}, expected ${expected}`);
    process.exit(1);
  }
}

// The property that matters is not the exact name but that it is a name:
// applications build paths out of an upload's client name.
for (const url of [
  "https://host/a%2F..%2F..%2Fetc%2Fpasswd",
  "https://host/..%2F..%2F.ssh%2Fid_rsa",
  "https://host/...",
  "https://host/%2E%2E%2F%2E%2E",
  "https://host/x/%00"
]) {
  const name = filenameFor(url, { type: "image/png" });

  if (!name || /[\\/]/.test(name) || name.startsWith(".") || name.includes("..")) {
    console.error(`filenameFor(${url}) produced a path, not a name: ${JSON.stringify(name)}`);
    process.exit(1);
  }
}

// `render_as` is declared once in Elixir and applied on both sides. Here is
// where the browser half is held to it: the real exported schema, the real
// toDOM, and the markup the server produces for the same node.
const renderOf = (built, type, attrs) => {
  const [, dom] = built.nodes[type].spec.toDOM(built.nodes[type].create(attrs));

  return dom && typeof dom === "object" && !Array.isArray(dom) ? dom : {};
};

for (const [type, attrs, expected] of [
  ["paragraph", { align: "center" }, { style: "text-align:center" }],
  ["heading", { level: 2, align: "right" }, { style: "text-align:right" }],
  ["list_item", { align: "justify" }, { style: "text-align:justify" }],
  ["paragraph", { align: null }, {}],
  // Not in the schema's list of values, so neither half renders it: a
  // document written under a looser schema must not reach a style attribute.
  ["paragraph", { align: "middle" }, {}]
]) {
  const actual = renderOf(schema, type, attrs);

  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    console.error(`toDOM of ${type} ${JSON.stringify(attrs)}`, { actual, expected });
    process.exit(1);
  }
}

// The other form, and the reason the mechanism is data: an application that
// would rather own the alignment in its stylesheet declares a class map and
// writes no JavaScript. Built from the real exported schema with that one
// declaration swapped, so what runs is the browser's branch and not a
// hand-written spec.
const classed = buildSchema({
  ...exported,
  nodes: exported.nodes.map(([name, spec]) =>
    name === "paragraph"
      ? [name, { ...spec, attrRenderAs: { align: { class: { center: "text-center" } } } }]
      : [name, spec]
  )
});

for (const [attrs, expected] of [
  [{ align: "center" }, { class: "text-center" }],
  // A value the map does not name contributes nothing: the map is its own
  // allow list, which is what makes it safe on a stored document.
  [{ align: "right" }, {}],
  [{ align: null }, {}]
]) {
  const actual = renderOf(classed, "paragraph", attrs);

  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    console.error(`class-mode toDOM of ${JSON.stringify(attrs)}`, { actual, expected });
    process.exit(1);
  }
}

// And read back, which is what copying a paragraph inside the editor does:
// ProseMirror serializes the selection through toDOM and parses it again
// through parseDOM. Rendering a value the editor cannot recognise would lose
// the alignment on paste, on the editor's own markup. No DOM here, and none
// needed — the read asks an element for two attributes.
const element = (attrs) => ({ getAttribute: (name) => attrs[name] ?? null });

const parsedBy = (built, type, tag, attrs) => {
  const rule = built.nodes[type].spec.parseDOM.find((rule) => rule.tag === tag);

  if (!rule?.getAttrs) {
    console.error(`no parseDOM rule with a getAttrs for ${type} <${tag}>`);
    process.exit(1);
  }

  return rule.getAttrs(element(attrs)) ?? {};
};

for (const [built, attrs, expected] of [
  [classed, { class: "text-center" }, { align: "center" }],
  // A class the map does not name is not this attribute's.
  [classed, { class: "prose lead" }, {}],
  [classed, {}, {}],
  // The shipped form reads its own style back, and refuses a value outside
  // the list the schema exported.
  [schema, { style: "text-align:right" }, { align: "right" }],
  [schema, { style: "color:red;text-align:justify" }, { align: "justify" }],
  [schema, { style: "text-align:middle" }, {}],
  // The rule's own extraction still wins where both answer: `align="right"`
  // is a shape import tolerates that no render_as emits.
  [schema, { align: "right" }, { align: "right" }]
]) {
  const actual = parsedBy(built, "paragraph", "p", attrs);
  const trimmed = Object.fromEntries(
    Object.entries(actual).filter(([, value]) => value !== null && value !== undefined)
  );

  if (JSON.stringify(trimmed) !== JSON.stringify(expected)) {
    console.error(`parseDOM of ${JSON.stringify(attrs)}`, { actual, expected });
    process.exit(1);
  }
}

if (srcOf('<img alt="a > b" src="/x.png">') !== "/x.png") {
  console.error("srcOf does not survive a quoted > in an earlier attribute");
  process.exit(1);
}

console.log(
  `ok: ${Object.keys(schema.nodes).length} nodes, ` +
    `${Object.keys(schema.marks).length} marks, document of ${doc.content.childCount} blocks`
);
