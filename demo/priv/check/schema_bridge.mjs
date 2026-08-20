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

if (srcOf('<img alt="a > b" src="/x.png">') !== "/x.png") {
  console.error("srcOf does not survive a quoted > in an earlier attribute");
  process.exit(1);
}

console.log(
  `ok: ${Object.keys(schema.nodes).length} nodes, ` +
    `${Object.keys(schema.marks).length} marks, document of ${doc.content.childCount} blocks`
);
