// The one thing no Elixir test can establish: that a person can type in this
// editor. Everything else — the schema bridge, the component tests — proves
// the halves fit; this proves the thing runs.
//
//   mix phx.server &            # or any running instance
//   node test/browser/editor.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";

const BASE = process.env.BASE_URL ?? "http://localhost:4321";
const EDITOR = ".coelho-content .ProseMirror";

let passed = 0;
let watched = [];

// Attributing a page error to the step that caused it is the difference
// between a bug report and a shrug.
const test = async (name, body) => {
  const before = watched.length;
  await body();
  const raised = watched.slice(before);
  if (raised.length) throw new Error(`${name} raised: ${raised.join(" | ")}`);
  passed += 1;
  console.log(`  ok  ${name}`);
};

const stored = (page) => page.$eval("#post_body", (el) => JSON.parse(el.value));
const pane = (page, name) => page.textContent(`[data-pane="${name}"]`);

// The server re-renders on every keystroke, so the panes lag the editor by a
// round trip.
const paneEventually = async (page, name, contains) => {
  await page.waitForFunction(
    ([name, contains]) =>
      document.querySelector(`[data-pane="${name}"]`)?.textContent?.includes(contains),
    [name, contains],
    { timeout: 5000 }
  );
  return pane(page, name);
};

const selectAll = (page) => page.keyboard.press("ControlOrMeta+a");

const typeInEditor = async (page, text) => {
  await page.click(EDITOR);
  await selectAll(page);
  await page.keyboard.type(text);
};

const run = async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = watched;

  page.on("pageerror", (error) => errors.push(process.env.STACKS ? error.stack : String(error)));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });

  await page.goto(BASE, { waitUntil: "networkidle" });

  try {
    await test("the editor mounts", async () => {
      await page.waitForSelector(EDITOR, { timeout: 5000 });
      assert.equal(await page.locator(EDITOR).count(), 1);
      // The sample document the server sent is what the editor shows.
      assert.match(await page.textContent(EDITOR), /The document is the storage/);
    });

    await test("typing reaches the document", async () => {
      await typeInEditor(page, "typed in a real browser");

      const document = await stored(page);
      assert.equal(document.content[0].content[0].text, "typed in a real browser");
    });

    await test("and reaches the server, which re-derives everything", async () => {
      assert.match(await paneEventually(page, "stored", "typed in a real browser"), /"type":"doc"/);
      assert.match(await pane(page, "html"), /<p>typed in a real browser<\/p>/);
      assert.equal((await pane(page, "text")).trim(), "typed in a real browser");
    });

    await test("the toolbar applies a mark to the selection", async () => {
      await typeInEditor(page, "bold me");
      await page.click(EDITOR);
      await selectAll(page);
      await page.click('[data-coelho-command="bold"]');

      const document = await stored(page);
      const [text] = document.content[0].content;
      assert.deepEqual(text.marks, [{ type: "bold" }]);
      assert.match(await paneEventually(page, "html", "<strong>"), /<strong>bold me<\/strong>/);
    });

    await test("the keyboard applies one too", async () => {
      await typeInEditor(page, "italic me");
      await selectAll(page);
      await page.keyboard.press("ControlOrMeta+i");

      const [text] = (await stored(page)).content[0].content;
      assert.deepEqual(text.marks, [{ type: "italic" }]);
    });

    await test("a heading is a heading, with its level", async () => {
      await typeInEditor(page, "a title");
      await page.click('[data-coelho-command="heading"]');

      const [block] = (await stored(page)).content;
      assert.equal(block.type, "heading");
      assert.equal(block.attrs.level, 2);
      assert.match(await paneEventually(page, "html", "<h2>"), /<h2>a title<\/h2>/);
    });

    await test("a list is built from the toolbar", async () => {
      await typeInEditor(page, "an item");
      await page.click('[data-coelho-command="bullet_list"]');

      const [block] = (await stored(page)).content;
      assert.equal(block.type, "bullet_list");
      assert.equal(block.content[0].type, "list_item");
    });

    await test("undo puts back what was there", async () => {
      await typeInEditor(page, "before undo");
      await page.keyboard.press("ControlOrMeta+z");

      assert.notEqual((await stored(page)).content[0].content?.[0]?.text, "before undo");
    });

    await test("an empty document advertises itself for the placeholder", async () => {
      await page.click(EDITOR);
      await selectAll(page);
      await page.keyboard.press("Backspace");

      await page.waitForFunction(() => document.querySelector(".coelho")?.classList.contains("coelho-empty"));
      assert.equal(
        await page.getAttribute(".coelho-content", "data-placeholder"),
        "Write something…"
      );
    });

    await test("an uploaded file becomes an attachment node and is served", async () => {
      const png = Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        "base64"
      );

      await page.click(EDITOR);
      await page.setInputFiles(".coelho-file-input", {
        name: "dot.png",
        mimeType: "image/png",
        buffer: png
      });

      await page.waitForFunction(
        () => JSON.parse(document.querySelector("#post_body").value).content
          .some((node) => node.type === "attachment"),
        null,
        { timeout: 10000 }
      );

      const node = (await stored(page)).content.find((n) => n.type === "attachment");
      assert.equal(node.attrs.filename, "dot.png");
      assert.ok(node.attrs.key, "the document stores a key");
      assert.equal(node.attrs.url, undefined, "and never a URL");

      // The editor shows a preview, and the server-rendered pane a signed URL.
      await page.waitForSelector(`.coelho-content figure[data-coelho-key="${node.attrs.key}"] img`);
      const rendered = await paneEventually(page, "html", "/attachments/");
      const [, url] = rendered.match(/src="([^"]+)"/);

      // The pane shows the HTML source as text, so the entities are still in
      // it; and the request context has no base URL of its own.
      const response = await page.request.get(BASE + url.replaceAll("&amp;", "&"));
      assert.equal(response.status(), 200);
      assert.equal(response.headers()["x-content-type-options"], "nosniff");
      assert.equal(Buffer.compare(Buffer.from(await response.body()), png), 0);
    });

    await test("nothing threw along the way", () => {
      assert.deepEqual(errors, []);
    });
  } finally {
    await browser.close();
  }

  console.log(`\n${passed} browser checks passed against ${BASE}`);
};

run().catch((error) => {
  console.error(`\nFAILED: ${error.message}`);
  process.exit(1);
});
