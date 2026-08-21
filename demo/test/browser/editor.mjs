// The one thing no Elixir test can establish: that a person can type in this
// editor. Everything else — the schema bridge, the component tests — proves
// the halves fit; this proves the thing runs.
//
//   mix phx.server &            # or any running instance
//   node test/browser/editor.mjs
import assert from "node:assert/strict";
import * as playwright from "playwright";

const BASE = process.env.BASE_URL ?? "http://localhost:4321";
// contenteditable and selection are where browsers disagree, which is
// exactly where every bug this file has found so far was hiding.
const BROWSER = process.env.BROWSER ?? "chromium";
// Scoped to the post editor: the page carries a second one, the draft note,
// and an unscoped selector would have every gesture land on whichever came
// first in the document.
const EDITOR = "#post_body-editor .coelho-content .ProseMirror";
const NOTE = "#note_body-editor .coelho-content .ProseMirror";
const NOTE_COUNT = "#note_body-editor [data-coelho-count]";

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
  try {
    await page.waitForFunction(
      ([name, contains]) =>
        document.querySelector(`[data-pane="${name}"]`)?.textContent?.includes(contains),
      [name, contains],
      { timeout: 5000 }
    );
  } catch {
    throw new Error(`pane ${name} never contained ${JSON.stringify(contains)}; it held ${JSON.stringify((await pane(page, name)) ?? "").slice(0, 400)}`);
  }
  return pane(page, name);
};

const spaces = (text) => text.replaceAll("\u00a0", " ");

const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64"
);

// A test that needs an attachment makes its own: depending on one another
// test happened to leave behind fails wherever that test is skipped.
const attach = async (page, name) => {
  await page.click(EDITOR);
  await page.setInputFiles(".coelho-file-input", { name, mimeType: "image/png", buffer: png });

  await documentEventually(
    page,
    `no attachment came back for ${name}`,
    "return doc.content.some((n) => n.type === 'attachment')"
  );
};

const LINK_INPUT = "[data-coelho-link-input]";
const HAS_LINK =
  "return doc.content.flatMap((b) => b.content ?? []).some((n) => n.marks?.some((m) => m.type === 'link'))";

const pressed = (page, command) =>
  page.getAttribute(`[data-coelho-command="${command}"]`, "aria-pressed");

const linkedFragments = async (page) =>
  (await stored(page)).content
    .flatMap((block) => block.content ?? [])
    .filter((node) => node.marks?.some((mark) => mark.type === "link"));

const hrefsIn = async (page) => {
  const hrefs = (await linkedFragments(page)).map(
    (node) => node.marks.find((mark) => mark.type === "link").attrs.href
  );

  return [...new Set(hrefs)].join(", ");
};

// The toolbar follows the selection, which the browser reports a tick later.
const settle = (page) => page.waitForTimeout(300);

const selectAll = (page) => page.keyboard.press("ControlOrMeta+a");

// A timeout that only says "timeout" costs an hour; one that shows the
// document costs a glance.
const documentEventually = async (page, description, predicate) => {
  try {
    await page.waitForFunction(
      (source) => new Function("doc", source)(JSON.parse(document.querySelector("#post_body").value)),
      predicate,
      { timeout: 5000 }
    );
  } catch {
    throw new Error(`${description}; document was ${JSON.stringify(await stored(page))}`);
  }
};

// Replaces the document and waits until it *is* what was typed. Without the
// wait, a slow machine can carry the previous test's document into the next
// one: a click landing before the editor is ready, or a select-all that has
// not taken, leaves the old content in place and the failure then points at
// whatever assertion came next rather than at the typing.
const EMPTY = 'return doc.content.flatMap((b) => b.content ?? []).every((n) => (n.text ?? "") === "")';

const isEmpty = async (page) =>
  (await stored(page)).content
    .flatMap((block) => block.content ?? [])
    .every((node) => (node.text ?? "") === "");

const typeInEditor = async (page, text) => {
  // A select-all sent before the click has moved focus selects nothing, and
  // the typing then *appends* to the previous test's document instead of
  // replacing it. Rather than ask the page whether it has focus — which the
  // engines answer differently — the gesture is repeated until it has had
  // the effect it is there for.
  for (let attempt = 1; ; attempt += 1) {
    await page.click(EDITOR);
    await selectAll(page);
    await page.keyboard.press("Backspace");
    await settle(page);

    if (await isEmpty(page)) break;

    if (attempt === 3) {
      await documentEventually(page, "the editor never emptied", EMPTY);
      break;
    }
  }

  await page.keyboard.type(text);

  await documentEventually(
    page,
    `the editor never came to hold ${JSON.stringify(text)}`,
    `return doc.content
       .flatMap((block) => block.content ?? [])
       .map((node) => node.text ?? "")
       .join("")
       .replaceAll("\\u00a0", " ") === ${JSON.stringify(text)}`
  );
};

const run = async () => {
  const browser = await playwright[BROWSER].launch();
  const page = await browser.newPage();
  const errors = watched;

  // `window.prompt` blocks the page and ignores the application's design; if
  // one ever comes back, the run says so instead of hanging.
  page.on("dialog", async (dialog) => {
    errors.push(`a ${dialog.type()} dialog opened: ${dialog.message()}`);
    await dialog.dismiss();
  });

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

    await test("the caret stays put across a server round trip", async () => {
      // Rebuilding the editor from the server's copy used to start a fresh
      // state, whose selection is at the top of the document — so the caret
      // jumped to the beginning whenever normalisation changed anything.
      await typeInEditor(page, "ABCDEF");
      await paneEventually(page, "stored", "ABCDEF");

      // In the middle, not at the end: a caret parked at the end of the
      // document passes an end-of-document test whether it was preserved or
      // moved there.
      await page.keyboard.press("End");
      for (let i = 0; i < 3; i += 1) await page.keyboard.press("ArrowLeft");
      await paneEventually(page, "stored", "ABCDEF");
      await page.keyboard.type("!");

      assert.equal(spaces(await page.textContent(EDITOR)), "ABC!DEF");
    });

    await test("a slow echo does not roll the writer back", async () => {
      // The server answers asynchronously, so an echo arriving now may
      // answer a keystroke from several ago. Applying it would put back what
      // had been typed by then — which is what a loaded machine sees and a
      // fast one hides.
      const sentence = "the quick brown fox jumps over the lazy dog";

      await page.click(EDITOR);
      await selectAll(page);
      await page.keyboard.type(sentence, { delay: 12 });
      await paneEventually(page, "stored", "lazy dog");

      assert.equal(spaces(await page.textContent(EDITOR)), sentence);
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

    await test("a mark is pressed only when it covers the whole selection", async () => {
      // `toggleMark` on a half-bold selection *adds* bold everywhere, so a
      // button pressed on "present somewhere" announces the opposite of what
      // clicking it does.
      await typeInEditor(page, "half bold");
      await page.keyboard.press("Home");
      for (let i = 0; i < 4; i += 1) await page.keyboard.press("Shift+ArrowRight");
      await page.click('[data-coelho-command="bold"]');

      assert.equal(await pressed(page, "bold"), "true", "on the bolded half");

      await page.click(EDITOR);
      await selectAll(page);
      await settle(page);

      assert.equal(await pressed(page, "bold"), "false", "on a half-bold selection");
    });

    await test("a link is made from the toolbar, not from a dialog", async () => {
      await typeInEditor(page, "see our terms");
      await page.click(EDITOR);
      await selectAll(page);
      await page.click('[data-coelho-command="link"]');

      assert.ok(await page.isVisible(LINK_INPUT), "the field opens");

      await page.fill(LINK_INPUT, "https://example.com/a");
      await page.keyboard.press("Enter");
      await documentEventually(page, "the link was not applied", HAS_LINK);

      assert.equal(await hrefsIn(page), "https://example.com/a");
      assert.ok(!(await page.isVisible(LINK_INPUT)), "and closes again");
    });

    await test("editing a link from the cursor rewrites all of it", async () => {
      // Two adjacent text nodes are only merged when their marks match, so a
      // link with a bold word inside is three fragments. Rewriting only the
      // one under the cursor would leave the rest on the old address — one
      // link on screen becoming two.
      // Built by typing rather than by arrow keys: where a caret lands after
      // Home and four rights is not the same in every engine.
      await typeInEditor(page, "see ");
      await page.keyboard.press("ControlOrMeta+b");
      await page.keyboard.type("our");
      await page.keyboard.press("ControlOrMeta+b");
      await page.keyboard.type(" terms");

      await page.click(EDITOR);
      await selectAll(page);
      await page.click('[data-coelho-command="link"]');
      await page.fill(LINK_INPUT, "https://old.example/x");
      await page.keyboard.press("Enter");
      await documentEventually(page, "the link was not applied", HAS_LINK);

      const fragments = await linkedFragments(page);
      assert.ok(fragments.length >= 3, `expected several fragments, got ${fragments.length}`);

      // Put the caret inside the link and open the field, repeating until it
      // comes up prefilled. Waiting for a condition and then clicking is not
      // enough: the state can change between the two, and where a caret lands
      // after ArrowLeft/ArrowRight is not the same in every engine — one run
      // put it at the *end* of the link, where an `inclusive: false` mark
      // deliberately does not apply, so there was nothing to edit.
      for (let attempt = 1; ; attempt += 1) {
        await page.click(EDITOR);
        await selectAll(page);
        await page.keyboard.press("ArrowLeft");
        await page.keyboard.press("ArrowRight");
        await settle(page);
        await page.click('[data-coelho-command="link"]');
        await settle(page);

        if ((await page.inputValue(LINK_INPUT)) === "https://old.example/x") break;

        assert.ok(attempt < 4, "the field never came up on the link under the caret");
        await page.keyboard.press("Escape");
      }

      await page.fill(LINK_INPUT, "https://new.example/y");
      await page.keyboard.press("Enter");
      await documentEventually(
        page,
        "the whole link was not rewritten",
        "return doc.content.flatMap((b) => b.content ?? []).every((n) => !n.marks?.some((m) => m.type === 'link') || n.marks.find((m) => m.type === 'link').attrs.href === 'https://new.example/y')"
      );

      assert.equal(await hrefsIn(page), "https://new.example/y");
    });

    await test("emptying the field removes the link and leaves the text", async () => {
      await typeInEditor(page, "linked text");
      await page.click(EDITOR);
      await selectAll(page);
      await page.click('[data-coelho-command="link"]');
      await page.fill(LINK_INPUT, "https://example.com/a");
      await page.keyboard.press("Enter");
      await documentEventually(page, "the link was not applied", HAS_LINK);

      await page.click(EDITOR);
      await selectAll(page);
      await page.click('[data-coelho-command="link"]');
      await page.fill(LINK_INPUT, "");
      await page.keyboard.press("Enter");
      await documentEventually(page, "the link was not removed", `return !(${HAS_LINK.slice(7)})`);

      assert.equal(spaces(await page.textContent(EDITOR)), "linked text");
    });

    await test("an address the browser would execute is refused", async () => {
      await typeInEditor(page, "tempting");
      await page.click(EDITOR);
      await selectAll(page);
      await page.click('[data-coelho-command="link"]');
      await page.fill(LINK_INPUT, "javascript:alert(1)");
      await page.keyboard.press("Enter");
      await settle(page);

      assert.ok(await page.isVisible(LINK_INPUT), "the field stays open");
      assert.equal(await linkedFragments(page).then((f) => f.length), 0, "nothing was linked");
    });

    await test("a heading is a heading, with its level", async () => {
      await typeInEditor(page, "a title");
      await page.click('[data-coelho-command="heading"]');

      const [block] = (await stored(page)).content;
      assert.equal(block.type, "heading");
      assert.equal(block.attrs.level, 2);
      assert.match(await paneEventually(page, "html", "<h2>"), /<h2>a title<\/h2>/);
    });

    await test("a block button undoes what it did", async () => {
      // Reported from using the demo: a heading could not be turned back into
      // a paragraph. `setBlockType` answers false for a block that is already
      // that type, so the button disabled *itself* the moment it worked —
      // which also reads as "it ignores my selection".
      await typeInEditor(page, "a block");

      for (const command of ["heading", "blockquote", "bullet_list", "ordered_list"]) {
        const button = `[data-coelho-command="${command}"]`;

        await page.click(button);
        await documentEventually(
          page,
          `${command} did not apply`,
          `return doc.content[0].type === "${command}"`
        );

        assert.ok(!(await page.isDisabled(button)), `${command} disabled itself`);

        await page.click(button);
        await documentEventually(
          page,
          `${command} did not come back off`,
          'return doc.content[0].type === "paragraph"'
        );
      }
    });

    await test("a list is built from the toolbar", async () => {
      await typeInEditor(page, "an item");
      await page.click('[data-coelho-command="bullet_list"]');

      const [block] = (await stored(page)).content;
      assert.equal(block.type, "bullet_list");
      assert.equal(block.content[0].type, "list_item");
    });

    await test("undo puts back what was there", async () => {
      // Also the check that a binding of the editor's own reaches it at all.
      // Mod-b, Mod-i and Shift-Enter were each tried here and each turned on
      // which of the browser and the page won the shortcut — Firefox on Linux
      // delivered neither Ctrl+I nor Shift+Enter to the page — which says
      // nothing about the editor.
      await typeInEditor(page, "before undo");
      await page.keyboard.press("ControlOrMeta+z");

      assert.notEqual((await stored(page)).content[0].content?.[0]?.text, "before undo");
    });

    await test("an empty document advertises itself for the placeholder", async () => {
      await page.click(EDITOR);
      await selectAll(page);
      await page.keyboard.press("Backspace");

      // On the editor's own element: a class on the root would be patched
      // away by the next render, so the placeholder would never show.
      await page.waitForFunction(
        () => document.querySelector(".ProseMirror")?.classList.contains("coelho-empty"),
        null,
        { timeout: 5000 }
      );

      // And it survives a server round trip. Waiting on the empty document
      // reaching the server is falsifiable; waiting on the text pane
      // containing "" is true on the first poll and waits for nothing.
      await paneEventually(page, "stored", '"content":[{"type":"paragraph"}]');
      assert.ok(
        await page.$eval(".ProseMirror", (el) => el.classList.contains("coelho-empty")),
        "the empty marker survives a render"
      );
      assert.equal(await page.getAttribute(".ProseMirror", "data-placeholder"), "Write something…");
    });

    await test("an uploaded file becomes an attachment node and is served", async () => {
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

    await test("an image pasted from another host is captured, not hotlinked", async () => {
      // Storing someone else's URL leaks every reader's address to that host
      // and breaks the day the file moves.
      // The same server on its other name: a different origin, so the capture
      // path runs, without hardcoding where the instance is.
      const remote = new URL("/remote-image.png", BASE.replace("localhost", "127.0.0.1")).href;

      await typeInEditor(page, "pasted:");

      const delivered = await page.evaluate((src) => {
        const transfer = new DataTransfer();
        transfer.setData("text/html", `<p>from elsewhere <img src="${src}"></p>`);
        const event = new ClipboardEvent("paste", {
          clipboardData: transfer,
          bubbles: true,
          cancelable: true
        });

        document.querySelector(".ProseMirror").dispatchEvent(event);
        return event.clipboardData?.getData("text/html")?.length > 0;
      }, remote);

      // Firefox and WebKit refuse to build a paste event carrying data, so
      // the mechanics can only be driven where they can.
      if (!delivered) {
        console.log("      (synthetic paste unavailable in this browser)");
        return;
      }

      await documentEventually(
        page,
        "the pasted image was not captured",
        "return doc.content.flatMap((b) => b.content ?? []).concat(doc.content).some((n) => n.type === 'attachment')"
      );

      const document_ = await stored(page);
      const nodes = document_.content.flatMap((block) => [block, ...(block.content ?? [])]);

      assert.ok(
        nodes.some((node) => node.type === "attachment"),
        "the bytes were stored as an attachment"
      );
      assert.ok(
        !nodes.some((node) => node.type === "image" && node.attrs.src === remote),
        "and no node kept pointing at the other host"
      );
      assert.match(spaces(await page.textContent(EDITOR)), /from elsewhere/);
    });

    await test("an attachment caption is written from the toolbar", async () => {
      // The caption is an attribute of the node, not content inside it, so
      // there is nowhere to type it: the button opens the same field the
      // link uses, on whichever selected node declares the attribute.
      // Typing leaves the caret in text, which is the state to ask about
      // first — before there is anything captionable to select at all.
      await typeInEditor(page, "with an attachment");
      await settle(page);

      assert.ok(
        await page.isDisabled('[data-coelho-command="caption"]'),
        "disabled with nothing captionable selected"
      );

      await attach(page, "captioned.png");
      await page.click(".coelho-content figure");
      await settle(page);

      assert.ok(!(await page.isDisabled('[data-coelho-command="caption"]')), "enabled on one");

      await page.click('[data-coelho-command="caption"]');
      await page.fill(LINK_INPUT, "Written from the toolbar");
      await page.keyboard.press("Enter");

      await documentEventually(
        page,
        "the caption was not written",
        `return doc.content.some((n) => n.attrs?.caption === "Written from the toolbar")`
      );

      assert.match(
        await paneEventually(page, "html", "Written from the toolbar"),
        /<figcaption>Written from the toolbar<\/figcaption>/
      );
    });

    await test("a node the application added to the schema round trips", async () => {
      await typeInEditor(page, "written by ");
      await paneEventually(page, "stored", "written by");
      await page.click('button[phx-click="mention"]');

      await documentEventually(
        page,
        "no mention was inserted",
        "return doc.content.flatMap((b) => b.content ?? []).some((n) => n.type === 'mention')"
      );

      // The document still holds what the earlier steps put in it, so the
      // mention is looked for rather than assumed to be at an index.
      const mention = (await stored(page)).content
        .flatMap((block) => block.content ?? [])
        .find((node) => node.type === "mention");

      assert.ok(mention, "the document holds a mention");
      // Inserted where the caret was, not at the top of the document. Where
      // exactly the surrounding text splits is ProseMirror's business and
      // varies with timing; what matters is that typed text precedes it.
      const paragraph = (await stored(page)).content.find((block) =>
        (block.content ?? []).some((node) => node.type === "mention")
      );
      const at = paragraph.content.findIndex((node) => node.type === "mention");

      assert.ok(at > 0, `the mention landed at index ${at}`);
      assert.match(spaces(paragraph.content[0].text ?? ""), /^written by/);
      assert.equal(mention.attrs.user_id, 7);
      assert.equal(mention.attrs.label, "@ada");

      // Rendered by the server from the same schema the browser is editing
      // against, and reduced to text by it too.
      assert.match(await paneEventually(page, "html", "mention"), /data-user-id="7"[^>]*>@ada</);
      // contenteditable keeps a trailing space alive as a non-breaking one,
      // and that is what gets stored, so it comes back out of the server too.
      assert.match(spaces(await pane(page, "text")), /written by @ada/);
      assert.match(spaces(await page.textContent(EDITOR)), /written by @ada/);
    });

    await test("composed input survives a server round trip", async () => {
      // Typing Japanese, or dictating, goes through composition events: the
      // browser holds a provisional string in the DOM and replaces it when
      // the writer commits. Nothing else here types anything but ASCII.
      //
      // What this covers: a composition committing correctly, and surviving
      // the round trip that follows. What it does not: an echo from the
      // server landing *during* a composition. The document does not change
      // while one is open, so nothing here provokes that, and it stays a
      // known gap rather than a claim.
      //
      // Only Chromium can be told to compose, through CDP.
      if (BROWSER !== "chromium") {
        console.log("      (composition can only be driven in chromium)");
        return;
      }

      await typeInEditor(page, "before ");

      const cdp = await page.context().newCDPSession(page);

      for (const provisional of ["n", "ni", "nihon"]) {
        await cdp.send("Input.imeSetComposition", {
          text: provisional,
          selectionStart: provisional.length,
          selectionEnd: provisional.length
        });
      }

      // Committing replaces the provisional string, it does not add to it.
      await cdp.send("Input.insertText", { text: "日本" });
      await settle(page);
      await paneEventually(page, "stored", "日本");

      const text = spaces(await page.textContent(EDITOR));

      assert.equal(text, "before 日本", `composition left ${JSON.stringify(text)}`);
      assert.match(await pane(page, "text"), /before 日本/);
    });

    await test("the toolbar can be worked without a mouse", async () => {
      // Not an accessibility audit — it is the floor: a button that only a
      // mouse can reach is a button half the people cannot use.
      await typeInEditor(page, "keyboard only");
      await page.click(EDITOR);
      await selectAll(page);

      await page.focus('[data-coelho-command="bold"]');
      await page.keyboard.press("Enter");

      await documentEventually(
        page,
        "the toolbar did not act on Enter",
        "return doc.content.flatMap((b) => b.content ?? []).some((n) => n.marks?.some((m) => m.type === 'bold'))"
      );

      // And it says what it is and what state it is in, which is what a
      // screen reader has to go on.
      const described = await page.$$eval("[data-coelho-command]", (buttons) =>
        buttons.every(
          (button) =>
            (button.getAttribute("aria-label") ?? "").length > 0 &&
            (button.hasAttribute("aria-pressed") || button.dataset.coelhoCommand === "undo" ||
              button.dataset.coelhoCommand === "redo" ||
              button.dataset.coelhoCommand === "caption")
        )
      );

      assert.ok(described, "every command is named, and says whether it is in force");
    });

    await test("a link can be made without touching the mouse at all", async () => {
      // Not `page.fill`, which focuses the field itself and would hide the
      // defect this covers: the command used to hand focus back to the
      // document the moment the field opened, so the field was on screen and
      // everything typed went into the text.
      await typeInEditor(page, "keyboard link");
      await page.click(EDITOR);
      await selectAll(page);

      await page.focus('[data-coelho-command="link"]');
      await page.keyboard.press("Enter");
      await settle(page);

      assert.ok(await page.isVisible(LINK_INPUT), "the field opens");

      const focused = await page.evaluate(
        () => document.activeElement === document.querySelector("[data-coelho-link-input]")
      );

      assert.ok(focused, "and keeps the focus it just took");

      await page.keyboard.type("https://keyboard.example/x");
      await page.keyboard.press("Enter");

      await documentEventually(page, "the link was not applied", HAS_LINK);
      assert.equal(await hrefsIn(page), "https://keyboard.example/x");
    });

    await test("it works under a finger, on a phone-sized screen", async () => {
      // The checks above run in a desktop viewport with a mouse. Nothing here
      // had ever been touched.
      const mobile = await browser.newContext({
        viewport: { width: 390, height: 844 },
        hasTouch: true
      });

      const small = await mobile.newPage();
      const raised = [];

      small.on("pageerror", (error) => raised.push(String(error)));

      try {
        await small.goto(BASE, { waitUntil: "networkidle" });
        await small.waitForSelector(EDITOR);

        await small.tap(EDITOR);
        await small.keyboard.press("ControlOrMeta+a");
        await small.keyboard.type("typed with a finger");

        await small.waitForFunction(
          () =>
            JSON.parse(document.querySelector("#post_body").value)
              .content.flatMap((block) => block.content ?? [])
              .map((node) => node.text ?? "")
              .join("") === "typed with a finger",
          null,
          { timeout: 5000 }
        );

        await small.tap('[data-coelho-command="bullet_list"]');

        await small.waitForFunction(
          () =>
            JSON.parse(document.querySelector("#post_body").value).content[0].type ===
            "bullet_list",
          null,
          { timeout: 5000 }
        );

        assert.deepEqual(raised, [], "nothing threw on the small screen");
      } finally {
        await mobile.close();
      }
    });

    await test("the toolbar speaks the language it was given", async () => {
      // The commands are not words. An application with readers who do not
      // speak English has to be able to say so, without rebuilding the
      // toolbar itself.
      const label = await page.textContent('#note_body-editor [data-coelho-command="bold"]');

      assert.equal(label.trim(), "Gras");
      assert.equal(
        await page.getAttribute('#note_body-editor [data-coelho-command="bold"]', "aria-label"),
        "Gras"
      );
    });

    await test("the counter is right before the hook has started, and after", async () => {
      // The server rendered the first number. Read it before touching
      // anything: a counter that starts at zero on an existing document is
      // read and believed long before the JavaScript has caught up.
      assert.equal((await page.textContent(NOTE_COUNT)).trim(), "4");

      await page.click(NOTE);
      await page.keyboard.press("End");
      await page.keyboard.type("!!");

      await page.waitForFunction(
        (selector) => document.querySelector(selector)?.textContent.trim() === "6",
        NOTE_COUNT,
        { timeout: 5000 }
      );
    });

    await test("the last keystrokes survive the editor leaving the page", async () => {
      // The one defect that cannot be found anywhere but here. A debounce
      // still holding the last edit when the element is removed loses it:
      // LiveView cancels the timer along with the element and nothing is
      // ever sent. The note editor has no phx-change at all, so the flush is
      // the only path its content can take — racing a real debounce would
      // make this pass or fail on how fast the engine types.
      await page.click(NOTE);
      await selectAll(page);
      await page.keyboard.press("Backspace");
      await page.keyboard.type("flux");

      const before = await page.textContent("#note-text");
      assert.ok(
        !before.includes("flux"),
        `something other than the flush sent it; #note-text held ${JSON.stringify(before)}`
      );

      await page.click("#note-toggle");

      await page.waitForFunction(
        () => document.querySelector("#note-text")?.textContent?.includes("flux"),
        null,
        { timeout: 5000 }
      );

      // Put the page back the way it was found.
      await page.click("#note-toggle");
      await page.waitForSelector(NOTE, { timeout: 5000 });
    });

    await test("and a flush from before a discard is refused", async () => {
      // The other half of the same mechanism. Discarding closes the editor,
      // so the editor being torn down pushes what was just thrown away; the
      // generation moved, so the token no longer matches and the push is
      // ignored. Without that, discarding puts the text straight back.
      await page.click(NOTE);
      await selectAll(page);
      await page.keyboard.press("Backspace");
      await page.keyboard.type("perdu");

      await page.click("#note-discard");
      await page.waitForFunction(
        () => !document.querySelector("#note-form"),
        null,
        { timeout: 5000 }
      );

      // Give a flush that was going to be accepted every chance to arrive.
      await page.waitForTimeout(500);

      const text = await page.textContent("#note-text");
      assert.ok(
        !text.includes("perdu"),
        `the discarded text came back; #note-text held ${JSON.stringify(text)}`
      );

      await page.click("#note-toggle");
      await page.waitForSelector(NOTE, { timeout: 5000 });
    });

    await test("nothing threw along the way", () => {
      assert.deepEqual(errors, []);
    });
  } finally {
    await browser.close();
  }

  console.log(`\n${passed} checks passed in ${BROWSER} against ${BASE}`);
};

run().catch((error) => {
  console.error(`\nFAILED in ${BROWSER}: ${error.message}`);
  process.exit(1);
});
