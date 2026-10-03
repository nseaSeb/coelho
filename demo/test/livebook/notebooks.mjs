// Runs every notebook in notebooks/ in a real Livebook, the way a reader who
// clicked "Run in Livebook" would: each cell evaluated in order, none may
// fail, the page may log no error — and in the tour, what is typed in the
// editor has to come back out of Elixir.
//
//   LIVEBOOK_URL=http://localhost:4555 node test/livebook/notebooks.mjs
//
// Livebook must run with its token disabled. Each notebook is copied with its
// Coelho dependency pointed at this checkout, so what is tested is the code
// beside it rather than whatever GitHub holds.
import { chromium } from "playwright";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../../..");
const BASE = process.env.LIVEBOOK_URL ?? "http://localhost:4555";
const work = mkdtempSync(join(tmpdir(), "coelho-notebooks-"));

const notebooks = readdirSync(join(root, "notebooks")).filter((name) => name.endsWith(".livemd"));
assert.ok(notebooks.length > 0, "no notebook found");

const local = (name) => {
  const source = readFileSync(join(root, "notebooks", name), "utf8");
  const pointed = source.replace(/\{:coelho, github: "[^"]+"\}/, `{:coelho, path: ${JSON.stringify(root)}}`);

  assert.notEqual(pointed, source, `${name}: no {:coelho, github: …} dependency to point at the checkout`);

  const path = join(work, name);
  writeFileSync(path, pointed);
  return path;
};

// `fresh` until evaluated, `evaluated` once it has run — set only when the
// evaluation finishes, unlike the status text, which a cell lacks until then.
const status = (cell) => cell.getAttribute("data-eval-validity").catch(() => "");

// Waits for one cell to be evaluated, then checks it did not raise.
const evaluated = async (page, cell, index, name) => {
  // The setup cell installs and compiles everything: minutes, the first time.
  const deadline = Date.now() + (index === 0 ? 600_000 : 90_000);
  let now = "";

  while (Date.now() < deadline) {
    now = await status(cell);
    if (now === "evaluated") break;
    await page.waitForTimeout(500);
  }

  assert.equal(now, "evaluated", `${name}, cell ${index}: still "${now}"`);

  const output = await cell.locator("[data-el-outputs-container]").innerText().catch(() => "");
  assert.doesNotMatch(output, /\*\* \(\w+/, `${name}, cell ${index} raised:\n${output.slice(0, 800)}`);
};

const browser = await chromium.launch();
let failed = 0;

for (const name of notebooks) {
  const page = await browser.newPage();
  const errors = [];

  page.on("pageerror", (error) => errors.push(error.message));

  try {
    await page.goto(`${BASE}/open?path=${encodeURIComponent(local(name))}`);
    await page.waitForSelector("[data-el-session]");

    const cells = page.locator("[data-el-cell][data-type='code']");
    const count = await cells.count();
    assert.ok(count > 1, `${name}: ${count} code cells`);

    // Livebook's own "evaluate all" (`e a` in navigation mode), which queues
    // every cell in order, setup first — what a reader does with the notebook.
    await page.locator("[data-el-session]").click({ position: { x: 5, y: 5 } }).catch(() => {});
    await page.keyboard.press("Escape");
    await page.keyboard.type("ea");

    for (let i = 0; i < count; i++) await evaluated(page, cells.nth(i), i, name);

    if (name === "tour.livemd") {
      // The editor is the first Kino output; the live view of what is stored
      // is the next one. Type, and the stored JSON has to follow.
      // A Kino output is an iframe, created when Livebook gets to it: wait
      // for the one holding the editor — the second code cell's output —
      // rather than looking once.
      let editor = null;

      for (let tries = 0; tries < 40 && !editor; tries++) {
        // Livebook creates a Kino output's iframe once its cell is on screen,
        // and evaluating every cell leaves the page scrolled to the last one.
        await cells.nth(1).scrollIntoViewIfNeeded().catch(() => {});

        for (const frame of page.frames()) {
          const found = await frame.locator(".ProseMirror").count().catch(() => 0);

          if (frame !== page.mainFrame() && found > 0) {
            editor = frame;
            break;
          }
        }

        if (!editor) await page.waitForTimeout(500);
      }

      assert.ok(editor, "tour.livemd: no editor rendered");
      const prose = editor.locator(".ProseMirror");

      await prose.click();
      await page.keyboard.press("End");
      await page.keyboard.type(" Typed in Livebook.");

      await page.waitForFunction(
        () => document.body.innerText.includes("Typed in Livebook."),
        null,
        { timeout: 10_000 }
      );

      // The tour's button calls set/2 now the editor is drawn and edited: the
      // document reaches it as an event, through the adapter's "set" handler.
      await page.getByRole("button", { name: "Write from Elixir" }).click();

      await prose.getByText("Typed in Livebook.").waitFor({ state: "detached", timeout: 10_000 });
      await prose.getByText("Written from Elixir.").waitFor({ timeout: 10_000 });
    }

    assert.deepEqual(errors, [], `${name}: errors in the page`);
    console.log(`  ok  ${name} (${count} cells)`);
  } catch (error) {
    failed++;
    console.log(`  FAIL ${name}\n${error.message}`);
    await page.screenshot({ path: join(work, `${name}.png`), fullPage: true });
  } finally {
    await page.close();
  }
}

await browser.close();

if (failed > 0) {
  console.log(`\n${failed} of ${notebooks.length} notebooks failed; screenshots in ${work}`);
  process.exit(1);
}

console.log(`\n${notebooks.length} notebooks ran in ${BASE}`);
