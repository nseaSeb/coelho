// Proves the two halves actually fit: the schema JSON Elixir exports is fed
// to the same code the browser runs, and must build a valid ProseMirror
// schema that can parse a real document. The Elixir-side drift test compares
// names; this one compares behaviour.
import { readFileSync } from "node:fs";
import { Node as PMNode } from "prosemirror-model";
import { buildSchema } from "../../../assets/js/coelho.js";

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

console.log(
  `ok: ${Object.keys(schema.nodes).length} nodes, ` +
    `${Object.keys(schema.marks).length} marks, document of ${doc.content.childCount} blocks`
);
