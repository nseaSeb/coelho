// Builds priv/static/coelho.esm.js, the hook with ProseMirror inside, so an
// application can use Coelho without installing a single npm package.
//
//   npm ci --prefix bundle && npm run build --prefix bundle
//   npm run check --prefix bundle   # fails when the committed file is stale
//
// The output is committed and shipped in the Hex package, so it has to be
// the same bytes on every machine: esbuild is pinned exactly, the working
// directory is fixed, and nothing in it depends on where it was built.
import { build, context } from "esbuild";
import { readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const outfile = join(root, "priv/static/coelho.esm.js");
const check = process.argv.includes("--check");
const watch = process.argv.includes("--watch");

const options = {
  absWorkingDir: root,
  entryPoints: ["bundle/entry.js"],
  bundle: true,
  format: "esm",
  target: "es2020",
  platform: "browser",
  // Bare imports resolve here and nowhere else. Node resolution walks up from
  // the importing file first, which is why the metafile is checked below
  // rather than trusted: a node_modules above assets/js would win silently.
  nodePaths: [join(here, "node_modules")],
  legalComments: "eof",
  // No version in it: a release would then have to rebuild the bundle to
  // change one comment, and the committed file would go stale on every bump.
  banner: { js: "// Coelho's hook with ProseMirror inside. Built by bundle/build.mjs; do not edit." },
  metafile: true,
  write: !check,
  outfile,
  logLevel: "warning"
};

// While working on coelho.js: rebuild on every save, without the checks below,
// which are for what gets committed.
if (watch) {
  const watching = await context({ ...options, logLevel: "info" });
  await watching.watch();
  console.log("watching assets/js/coelho.js");
  await new Promise(() => {});
}

const result = await build(options);

// Every package in the bundle comes from bundle/node_modules, and each of the
// ProseMirror cores exactly once: two copies of prosemirror-model are two
// sets of classes, and an editor built across them never mounts.
const inputs = Object.keys(result.metafile.inputs);

for (const input of inputs) {
  if (input.includes("node_modules/") && !input.startsWith("bundle/node_modules/")) {
    throw new Error(`${input} was resolved outside bundle/node_modules`);
  }
}

for (const core of ["model", "state", "view", "transform"]) {
  const copies = new Set(
    inputs
      .filter((input) => input.includes(`/prosemirror-${core}/`))
      .map((input) => input.slice(0, input.indexOf(`/prosemirror-${core}/`)))
  );

  if (copies.size !== 1) {
    throw new Error(`prosemirror-${core} is in the bundle ${copies.size} times: ${[...copies].join(", ")}`);
  }
}

// Everything coelho.js exports is exported here too: an application moving
// from the npm path to the bundle changes an import, not its code.
const source = await build({
  absWorkingDir: root,
  entryPoints: ["assets/js/coelho.js"],
  bundle: true,
  format: "esm",
  nodePaths: [join(here, "node_modules")],
  metafile: true,
  write: false,
  outdir: "bundle/out",
  logLevel: "warning"
});

const exportsOf = (metafile) => new Set(Object.values(metafile.outputs)[0].exports);
const shipped = exportsOf(result.metafile);
const missing = [...exportsOf(source.metafile)].filter((name) => !shipped.has(name));

if (missing.length > 0) {
  throw new Error(`the bundle does not export ${missing.join(", ")}`);
}

const bytes = Object.values(result.metafile.outputs)[0].bytes;

if (check) {
  const committed = readFileSync(outfile);
  const built = Buffer.from(result.outputFiles[0].contents);

  if (!committed.equals(built)) {
    console.error(`${relative(root, outfile)} is stale: run npm run build --prefix bundle and commit it`);
    process.exit(1);
  }

  console.log(`${relative(root, outfile)} is up to date (${bytes} bytes)`);
} else {
  console.log(`wrote ${relative(root, outfile)} (${bytes} bytes)`);
}
