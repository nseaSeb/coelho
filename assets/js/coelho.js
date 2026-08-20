import { createHook } from "@nseaprotector/acme-script";
import OrderedMap from "orderedmap";
import { Schema, Node as PMNode } from "prosemirror-model";
import { EditorState, Selection, TextSelection } from "prosemirror-state";
import { EditorView } from "prosemirror-view";
import { keymap } from "prosemirror-keymap";
import { baseKeymap, toggleMark, setBlockType, wrapIn, chainCommands, exitCode } from "prosemirror-commands";
import { history, undo, redo } from "prosemirror-history";
import { wrapInList, splitListItem, liftListItem, sinkListItem } from "prosemirror-schema-list";

// The document model, its validation and its server-side rendering all live
// in Elixir. This file is only the browser half: it turns the schema the
// server exported into a ProseMirror schema, mounts an editor on it, and
// writes the document back into a hidden input so the whole thing behaves
// like an ordinary form field.
//
// The one thing Elixir cannot express is how a node looks in the editor —
// toDOM/parseDOM are functions. Those live here, keyed by node name, and
// `createCoelhoHook` lets an application add its own.

const clampLevel = (level) => (Number.isInteger(level) && level >= 1 && level <= 6 ? level : 1);

// Preview URLs live outside the document, keyed by attachment key.
const previewUrls = new Map();

export const setPreviewUrl = (key, url) => {
  if (key && url) previewUrls.set(key, url);
};

export const defaultNodeDOM = {
  paragraph: {
    toDOM: () => ["p", 0],
    parseDOM: [{ tag: "p" }]
  },
  heading: {
    toDOM: (node) => ["h" + clampLevel(node.attrs.level), 0],
    parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({ tag: `h${level}`, attrs: { level } }))
  },
  blockquote: {
    toDOM: () => ["blockquote", 0],
    parseDOM: [{ tag: "blockquote" }]
  },
  bullet_list: {
    toDOM: () => ["ul", 0],
    parseDOM: [{ tag: "ul" }]
  },
  ordered_list: {
    toDOM: (node) => (node.attrs.start === 1 ? ["ol", 0] : ["ol", { start: node.attrs.start }, 0]),
    parseDOM: [{ tag: "ol", getAttrs: (dom) => ({ start: +(dom.getAttribute("start") || 1) }) }]
  },
  list_item: {
    toDOM: () => ["li", 0],
    parseDOM: [{ tag: "li" }],
    defining: true
  },
  code_block: {
    toDOM: (node) => [
      "pre",
      ["code", node.attrs.language ? { class: "language-" + node.attrs.language } : {}, 0]
    ],
    parseDOM: [{ tag: "pre", preserveWhitespace: "full" }],
    code: true,
    defining: true
  },
  horizontal_rule: {
    toDOM: () => ["hr"],
    parseDOM: [{ tag: "hr" }]
  },
  image: {
    toDOM: (node) => ["img", { src: node.attrs.src, alt: node.attrs.alt, title: node.attrs.title }],
    parseDOM: [
      {
        tag: "img[src]",
        getAttrs: (dom) => ({
          src: dom.getAttribute("src"),
          alt: dom.getAttribute("alt"),
          title: dom.getAttribute("title")
        })
      }
    ],
    draggable: true
  },
  // The document stores an attachment key, never a URL — the server resolves
  // it at render time so signed and expiring URLs work. The editor still has
  // to show something, so preview URLs are kept beside the document and
  // consulted here; they are deliberately not part of the schema, or they
  // would end up stored and stale.
  attachment: {
    toDOM: (node) => {
      const url = previewUrls.get(node.attrs.key);
      const label = node.attrs.filename ?? node.attrs.key;
      const body =
        url && (node.attrs.content_type ?? "").startsWith("image/")
          ? ["img", { src: url, alt: node.attrs.alt ?? "" }]
          : ["span", { class: "coelho-attachment-label" }, label];

      return ["figure", { class: "coelho-attachment", "data-coelho-key": node.attrs.key }, body];
    },
    parseDOM: [
      {
        tag: "figure[data-coelho-key]",
        getAttrs: (dom) => ({ key: dom.getAttribute("data-coelho-key") })
      }
    ],
    draggable: true
  },
  hard_break: {
    toDOM: () => ["br"],
    parseDOM: [{ tag: "br" }],
    selectable: false
  }
};

export const defaultMarkDOM = {
  bold: {
    toDOM: () => ["strong", 0],
    parseDOM: [{ tag: "strong" }, { tag: "b" }, { style: "font-weight=bold" }]
  },
  italic: {
    toDOM: () => ["em", 0],
    parseDOM: [{ tag: "em" }, { tag: "i" }, { style: "font-style=italic" }]
  },
  strike: {
    toDOM: () => ["s", 0],
    parseDOM: [{ tag: "s" }, { tag: "del" }, { style: "text-decoration=line-through" }]
  },
  code: {
    toDOM: () => ["code", 0],
    parseDOM: [{ tag: "code" }]
  },
  link: {
    toDOM: (mark) => ["a", { href: mark.attrs.href, title: mark.attrs.title }, 0],
    parseDOM: [
      {
        tag: "a[href]",
        getAttrs: (dom) => ({ href: dom.getAttribute("href"), title: dom.getAttribute("title") })
      }
    ],
    inclusive: false
  }
};

// The server exports nodes and marks as ordered [name, spec] pairs rather
// than as objects: ProseMirror resolves default types by position, and map
// key order does not survive a round trip through Elixir.
const toOrderedMap = (pairs, dom) => {
  let map = OrderedMap.from({});

  for (const [name, spec] of pairs) {
    map = map.addToEnd(name, { ...spec, ...(dom[name] ?? {}) });
  }

  return map;
};

export const buildSchema = (exported, { nodes = {}, marks = {} } = {}) =>
  new Schema({
    topNode: exported.topNode,
    nodes: toOrderedMap(exported.nodes, { ...defaultNodeDOM, ...nodes }),
    marks: toOrderedMap(exported.marks, { ...defaultMarkDOM, ...marks })
  });

// -- Commands ---------------------------------------------------------------

// A URL the browser would execute rather than fetch. The schema refuses
// these on the way in, but a document that is only rejected once the writer
// has moved on is a dead end; this says no while the field is still open.
const EXECUTABLE = /^\s*(javascript|data|vbscript):/i;

const commandFor = (name, schema, options) => {
  const { nodes, marks } = schema;

  switch (name) {
    case "bold":
    case "italic":
    case "strike":
    case "code":
      return marks[name] && toggleMark(marks[name]);
    case "link":
      // Asked whether it *could* run — which is what the toolbar does on
      // every selection change — it must not go and open anything.
      return (
        marks.link &&
        ((state, dispatch, view) => {
          if (dispatch) view.coelhoEditLink();
          return true;
        })
      );
    case "caption":
      return (state, dispatch, view) => {
        if (!captionable(state)) return false;
        if (dispatch) view.coelhoEditCaption();
        return true;
      };
    case "heading":
      return (
        nodes.heading &&
        setBlockType(nodes.heading, { level: Number(options.level ?? 2) })
      );
    case "paragraph":
      return nodes.paragraph && setBlockType(nodes.paragraph);
    case "code_block":
      return nodes.code_block && setBlockType(nodes.code_block);
    case "blockquote":
      return nodes.blockquote && wrapIn(nodes.blockquote);
    case "bullet_list":
      return nodes.bullet_list && wrapInList(nodes.bullet_list);
    case "ordered_list":
      return nodes.ordered_list && wrapInList(nodes.ordered_list);
    case "horizontal_rule":
      return (
        nodes.horizontal_rule &&
        ((state, dispatch) => {
          if (dispatch) dispatch(state.tr.replaceSelectionWith(nodes.horizontal_rule.create()));
          return true;
        })
      );
    case "undo":
      return undo;
    case "redo":
      return redo;
    default:
      return null;
  }
};

// -- Toolbar state ----------------------------------------------------------

// A toolbar that never says what is in force leaves the writer guessing
// whether the last click did anything.
// A mark is active when it covers the *whole* selection — or, with no
// selection, when it would apply to the next keystroke (`storedMarks`, which
// ProseMirror sets after toggling with an empty selection).
//
// Not `rangeHasMark`, which answers "present somewhere": on a half-bold
// selection the button *adds* bold everywhere, so showing it pressed
// announces the opposite of what clicking it does.
const markActive = (state, type) => {
  const { from, $from, to, empty } = state.selection;

  if (empty) return Boolean(type.isInSet(state.storedMarks || $from.marks()));

  let sawText = false;
  let throughout = true;

  state.doc.nodesBetween(from, to, (node) => {
    if (!node.isText) return;

    sawText = true;
    if (!type.isInSet(node.marks)) throughout = false;
  });

  return sawText && throughout;
};

// `attrs` stays undefined when the caller has none to match: `hasMarkup`
// falls back to the type's defaults, and `{}` — being truthy — would stop it,
// so every block declaring an attribute would compare false forever.
const blockActive = (state, type, attrs) => {
  const { $from, node } = state.selection;

  if (node) return node.hasMarkup(type, attrs);

  // Anywhere above the cursor counts: a list and a quote can both be in
  // force at once, and a heading is still a heading when the whole document
  // is selected. Asking whether the selection *ends* inside the block, the
  // way the usual snippet does, answers no on a select-all.
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    if ($from.node(depth).hasMarkup(type, attrs)) return true;
  }

  return false;
};

// The extent of the link under the cursor. ProseMirror gives the mark, not
// the range it covers, and a link is rarely one text node: two adjacent text
// nodes are only merged when their marks are *identical*, so "see our terms"
// with one bold word inside is three fragments. Rewriting only the fragment
// under the cursor would leave the other two pointing at the old URL — one
// link on screen becoming two different links.
const linkAround = (state, type) => {
  const { $from } = state.selection;
  const mark = type.isInSet($from.marks()) || type.isInSet($from.nodeAfter?.marks ?? []);

  if (!mark) return null;

  const pieces = [];
  let pos = $from.start();

  $from.parent.forEach((child) => {
    const start = pos;
    pos += child.nodeSize;
    pieces.push({ start, end: pos, linked: child.isText && mark.isInSet(child.marks) });
  });

  const index = pieces.findIndex(
    (piece) => piece.linked && piece.start <= $from.pos && $from.pos <= piece.end
  );

  if (index === -1) return null;

  // `mark.isInSet` compares attributes too, so two neighbouring links with
  // different addresses stay two links.
  let first = index;
  let last = index;

  while (first > 0 && pieces[first - 1].linked) first -= 1;
  while (last < pieces.length - 1 && pieces[last + 1].linked) last += 1;

  return { from: pieces[first].start, to: pieces[last].end, href: mark.attrs.href };
};

// The node a caption can be put on: one that is selected and that declares
// the attribute. Nothing else can be captioned, and the button says so by
// being disabled.
const captionable = (state) => {
  const { node, from } = state.selection;

  return node && "caption" in (node.type.spec.attrs ?? {}) ? { node, pos: from } : null;
};

const commandActive = (state, name, options) => {
  const { nodes, marks } = state.schema;

  switch (name) {
    case "bold":
    case "italic":
    case "strike":
    case "code":
      return marks[name] ? markActive(state, marks[name]) : false;
    case "link":
      return marks.link ? markActive(state, marks.link) : false;
    case "heading":
      return nodes.heading
        ? blockActive(state, nodes.heading, { level: Number(options.level ?? 2) })
        : false;
    case "paragraph":
    case "code_block":
    case "blockquote":
    case "bullet_list":
    case "ordered_list":
      return nodes[name] ? blockActive(state, nodes[name]) : false;
    default:
      return null;
  }
};

const buildKeymap = (schema) => {
  const { nodes, marks } = schema;
  const bindings = {
    "Mod-z": undo,
    "Shift-Mod-z": redo,
    "Mod-y": redo
  };

  if (marks.bold) bindings["Mod-b"] = toggleMark(marks.bold);
  if (marks.italic) bindings["Mod-i"] = toggleMark(marks.italic);
  if (marks.code) bindings["Mod-e"] = toggleMark(marks.code);

  if (nodes.list_item) {
    bindings["Enter"] = splitListItem(nodes.list_item);
    bindings["Mod-["] = liftListItem(nodes.list_item);
    bindings["Mod-]"] = sinkListItem(nodes.list_item);
  }

  if (nodes.hard_break) {
    const insert = chainCommands(exitCode, (state, dispatch) => {
      if (dispatch) {
        dispatch(state.tr.replaceSelectionWith(nodes.hard_break.create()).scrollIntoView());
      }
      return true;
    });

    bindings["Shift-Enter"] = insert;
    bindings["Mod-Enter"] = insert;
  }

  return bindings;
};

// Offsets survive the round trip when the text around them does; when the
// server changed enough that they no longer point at text, the nearest
// position is the best answer available.
const selectionAt = (doc, from, to) => {
  const end = doc.content.size;
  const [start, stop] = [Math.min(from, end), Math.min(to, end)];

  try {
    return TextSelection.create(doc, start, stop);
  } catch {
    return Selection.near(doc.resolve(start));
  }
};

// Someone else's host — not a relative URL, not our own origin, which is
// where our own attachments already live.
export const isRemote = (src) => {
  const here = globalThis.location;
  if (!here) return false;

  try {
    const url = new URL(src, here.href);
    return /^https?:$/.test(url.protocol) && url.origin !== here.origin;
  } catch {
    return false;
  }
};

// Attribute values can hold a quoted `>`, so the tag is matched as
// alternating plain text and quoted runs rather than "anything but >".
const IMG_TAG = /<img\b(?:[^>"']|"[^"]*"|'[^']*')*>/gi;
const SRC_ATTR = /\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i;

export const srcOf = (tag) => {
  const match = SRC_ATTR.exec(tag);
  return match ? match[1] ?? match[2] ?? match[3] : null;
};

// The name reaches the server as the upload's client name, and applications
// build paths out of those. A percent-encoded `..%2F` in someone else's URL
// must not come out the other side as a path.
export const filenameFor = (url, blob) => {
  const [, extension = "bin"] = (blob.type || "").split("/");

  let name = "";

  try {
    // No base outside a browser, which is where the checks run: an absolute
    // URL needs none, and a relative one is not somebody else's host anyway.
    const parsed = new URL(url, globalThis.location?.href);
    name = decodeURIComponent(parsed.pathname.split("/").pop() || "");
  } catch {
    name = "";
  }

  name = name
    .replace(/[\\/]/g, "")
    .replace(/\.{2,}/g, ".")
    .replace(/^\.+|\.+$/g, "")
    .trim();

  if (!name) return `pasted.${extension}`;
  return /\.[a-z0-9]+$/i.test(name) ? name : `${name}.${extension}`;
};

// Marks a transaction as the server's, not the writer's.
const REMOTE = "coelho:remote";

const parseDoc = (schema, value) => {
  try {
    return PMNode.fromJSON(schema, JSON.parse(value));
  } catch {
    return null;
  }
};

// -- Hook -------------------------------------------------------------------

export const createCoelhoHook = (dom = {}) =>
  createHook({
    mounted(ctx) {
      const el = ctx.el;
      const exported = JSON.parse(el.dataset.coelhoSchema);
      const input = document.getElementById(el.dataset.coelhoInput);
      const content = el.querySelector(".coelho-content");

      const schema = buildSchema(exported, dom);
      this._schema = schema;
      this._input = input;
      this._written = new Set();
      this._pending = new Map();

      // A bounded memory of what this editor has put in the input.
      this.remember = (json) => {
        this._written.add(json);
        if (this._written.size > 20) {
          this._written.delete(this._written.values().next().value);
        }
      };

      const state = EditorState.create({
        doc: parseDoc(schema, input.value) ?? schema.topNodeType.createAndFill(),
        plugins: [history(), keymap(buildKeymap(schema)), keymap(baseKeymap)]
      });

      this._view = new EditorView(content, {
        state,
        transformPastedHTML: (html) => (uploadName ? this.captureFrom(html) : html),
        dispatchTransaction: (transaction) => {
          this._view.updateState(this._view.state.apply(transaction));
          this.refreshToolbar();

          // `_pendingLink` is a pair of positions, and any edit shifts them.
          // With the field still open, confirming afterwards would have put
          // the link on a stretch of text that is no longer the one aimed at.
          if (transaction.docChanged && this._pendingField) this.closeField({ focus: false });

          // Writing the input back when the change *came from* the server
          // would post it straight back: the server normalises, so its copy
          // never quite equals what the editor wrote, and the two would
          // trade rounds forever.
          if (transaction.docChanged && !transaction.getMeta(REMOTE)) this.syncInput();
        }
      });

      // Runs while the paste is still being parsed, so it is synchronous:
      // the images come out of the HTML now, and their bytes follow.
      this.captureFrom = (html) => {
        const urls = [];

        // The tags are cut out of the string rather than out of a parsed
        // document: clipboard HTML is often a context-sensitive fragment — a
        // table row, a list item — and a DOMParser round trip through
        // `body.innerHTML` throws away exactly those.
        const stripped = html.replace(IMG_TAG, (tag) => {
          const src = srcOf(tag);

          if (!isRemote(src)) return tag;

          urls.push(src);
          return "";
        });

        if (!urls.length) return html;

        this.captureImages(urls);
        return stripped;
      };

      this.syncInput = () => {
        const json = JSON.stringify(this._view.state.doc.toJSON());
        // Remember what we wrote — and not only the last one. The server
        // echoes asynchronously, so an echo arriving now may answer a
        // keystroke from several ago; applying it would roll the writer back
        // to what they had typed by then.
        this.remember(json);

        if (input.value !== json) {
          input.value = json;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        }
        // On the editor's own element, which lives inside the ignored
        // container: LiveView patches an element's attributes even when it
        // spares its children, so a class set on the root or on the
        // container is undone by the next render.
        this._view.dom.classList.toggle("coelho-empty", !this._view.state.doc.textContent);
      };

      this._onToolbar = (event) => {
        const button = event.target.closest("[data-coelho-command]");
        if (!button || !el.contains(button)) return;

        event.preventDefault();
        const command = commandFor(button.dataset.coelhoCommand, schema, button.dataset);
        if (command) {
          command(this._view.state, this._view.dispatch, this._view);
          this._view.focus();
        }
      };

      el.addEventListener("mousedown", this._onToolbar);

      this._linkZone = el.querySelector("[data-coelho-link-zone]");
      this._linkInput = el.querySelector("[data-coelho-link-input]");

      // One field, whatever asked for it. What it does on Enter is decided
      // when it opens, because the selection is what says what to act on and
      // a field that took the focus would lose the answer.
      this.openField = ({ value, label, apply }) => {
        if (!this._linkInput) return;

        this._pendingField = apply;
        this._linkZone.hidden = false;
        this._linkInput.value = value ?? "";
        this._linkInput.setAttribute("aria-label", label);
        this._linkInput.focus();
        this._linkInput.select();
      };

      this.closeField = ({ focus = true } = {}) => {
        this._pendingField = null;

        if (this._linkZone) this._linkZone.hidden = true;
        if (this._linkInput) this._linkInput.value = "";
        if (focus) this._view.focus();
      };

      this.confirmField = (value) => {
        if (!this._pendingField) return this.closeField();

        const refusal = this._pendingField(value);

        // An apply that hands back a reason keeps the field open with it
        // showing, rather than letting the writer walk away from a change
        // that never happened.
        if (typeof refusal === "string") {
          this._linkInput.setCustomValidity(refusal);
          this._linkInput.reportValidity();
          return undefined;
        }

        return this.closeField();
      };

      this.applyLink = ({ from, to }) => (href) => {
        const link = this._schema.marks.link;
        if (!link) return undefined;

        if (href && EXECUTABLE.test(href)) return "This kind of address cannot be linked.";

        const { state } = this._view;

        // An emptied field removes the link and leaves the text alone, which
        // is the gesture people reach for; the button then only ever opens
        // the field.
        const transaction = href
          ? state.tr.removeMark(from, to, link).addMark(from, to, link.create({ href }))
          : state.tr.removeMark(from, to, link);

        this._view.dispatch(transaction);
        return undefined;
      };

      // A caption is an attribute of the node, not content inside it, so it
      // is set rather than typed into: the alternative is a node view that
      // mirrors an editable region back into an attribute, which is a lot of
      // machinery for one line of text.
      this.applyCaption = (pos) => (caption) => {
        const { state } = this._view;
        const node = state.doc.nodeAt(pos);
        if (!node) return undefined;

        this._view.dispatch(
          state.tr.setNodeMarkup(pos, null, { ...node.attrs, caption: caption || null })
        );

        return undefined;
      };

      this.editCaption = () => {
        const selected = captionable(this._view.state);
        if (!selected) return;

        this.openField({
          value: selected.node.attrs.caption ?? "",
          label: "Caption",
          apply: this.applyCaption(selected.pos)
        });
      };

      this.editLink = () => {
        const link = this._schema.marks.link;
        if (!link) return;

        // An application with its own link UI takes over from here.
        const event = new CustomEvent("coelho:link", {
          bubbles: true,
          cancelable: true,
          detail: {
            selection: this._view.state.selection,
            apply: (href) => this.confirmField(href)
          }
        });

        el.dispatchEvent(event);
        if (event.defaultPrevented) return;

        const { state } = this._view;
        const existing = linkAround(state, link);

        // The selection wins: it says what the writer is aiming at. Serving
        // the link under the cursor first would quietly ignore a selection
        // reaching past it, and "extend this link" would extend nothing.
        if (!state.selection.empty) {
          const { from, to } = state.selection;
          this.openField({
            value: existing?.href ?? "",
            label: "Link address",
            apply: this.applyLink({ from, to })
          });
        } else if (existing) {
          this.openField({
            value: existing.href,
            label: "Link address",
            apply: this.applyLink(existing)
          });
        }
      };

      if (this._linkInput) {
        this._onLinkKey = (event) => {
          this._linkInput.setCustomValidity("");

          if (event.key === "Enter") {
            event.preventDefault();
            this.confirmField(this._linkInput.value.trim());
          } else if (event.key === "Escape") {
            event.preventDefault();
            this.closeField();
          }
        };

        this._linkInput.addEventListener("keydown", this._onLinkKey);
      }

      this.refreshToolbar = () => {
        const { state } = this._view;

        for (const button of el.querySelectorAll("[data-coelho-command]")) {
          const name = button.dataset.coelhoCommand;
          const active = commandActive(state, name, button.dataset);

          if (active !== null) button.setAttribute("aria-pressed", String(active));

          const command = commandFor(name, state.schema, button.dataset);
          button.disabled = Boolean(command) && !command(state, null, this._view);
        }
      };

      // Anything the server decides to put in the document arrives here: an
      // attachment it has just stored, a mention it has just resolved, an
      // embed. The node is the server's, built against the same schema.
      this.insertNode = (nodeJSON, preview, { focus = true } = {}) => {
        setPreviewUrl(nodeJSON.attrs?.key, preview);
        this._pending.delete(nodeJSON.attrs?.filename);

        const node = PMNode.fromJSON(this._schema, nodeJSON);

        // Whatever asked for the node took focus away, so the editor is
        // focused first and the node lands at the caret. If the writer has
        // since moved on — an insertion arriving seconds later, a failed
        // capture — replacing their selection would destroy what they are
        // doing, so it goes at the end instead.
        if (focus) this._view.focus();

        const { state } = this._view;
        const transaction = this._view.hasFocus()
          ? state.tr.replaceSelectionWith(node)
          : state.tr.insert(state.doc.content.size, node);

        this._view.dispatch(transaction.scrollIntoView());
      };

      // push_event reaches the whole page, so an insertion meant for one
      // editor would otherwise land in every editor on it.
      ctx.handle("coelho:insert", ({ node, id, preview }) => {
        if (id == null || id === el.id) this.insertNode(node, preview);
      });

      const uploadName = el.dataset.coelhoUpload;

      // An image pasted from a web page arrives as a URL on someone else's
      // host. Storing that is a hotlink: it leaks every reader's address to
      // that host, and breaks the day the file moves. When an upload is
      // configured, the bytes are fetched and go through the same path as a
      // dropped file; when it is not, the URL is kept as it always was.
      this.captureImages = async (urls) => {
        for (const url of urls) {
          try {
            const response = await fetch(url, { mode: "cors", credentials: "omit" });
            if (!response.ok) throw new Error(`responded ${response.status}`);

            const blob = await response.blob();
            const filename = filenameFor(url, blob);

            this._pending.set(filename, url);
            ctx.upload(uploadName, [new File([blob], filename, { type: blob.type })]);

            // `upload` is fire and forget: an entry refused for being one too
            // many, too large, or the wrong type raises nothing here, and the
            // image would vanish without a word. If nothing comes back for it,
            // the URL goes in after all.
            setTimeout(() => this.captureFailed(filename, "the upload never came back"), 15000);
          } catch (error) {
            // Usually CORS: the bytes can be displayed but not read.
            this.captureFailed(filenameFor(url, { type: "" }), error, url);
          }
        }
      };

      this.captureFailed = (filename, reason, url = this._pending.get(filename)) => {
        if (url === undefined) return;

        this._pending.delete(filename);
        el.dispatchEvent(
          new CustomEvent("coelho:capture-failed", { bubbles: true, detail: { url, reason } })
        );

        if (this._schema.nodes.image) {
          this.insertNode({ type: "image", attrs: { src: url } }, null, { focus: false });
        }
      };

      if (uploadName) {
        this._onFiles = (event) => {
          const files = [...(event.dataTransfer ?? event.clipboardData)?.files ?? []];
          if (!files.length) return;

          event.preventDefault();
          ctx.upload(uploadName, files);
        };

        content.addEventListener("drop", this._onFiles);
        content.addEventListener("paste", this._onFiles);
      }

      // The link command only gets `(state, dispatch, view)`, so the view is
      // where it can find its way back to the editor's own machinery.
      this._view.coelhoEditLink = () => this.editLink();
      this._view.coelhoEditCaption = () => this.editCaption();

      this._content = content;

      // Same reason: the server renders the placeholder onto the container,
      // and it is carried inside where nothing will patch it away.
      if (content.dataset.placeholder) {
        this._view.dom.dataset.placeholder = content.dataset.placeholder;
      }

      this.syncInput();
      this.refreshToolbar();

      // Moving the caret changes what is in force without changing the
      // document, and that never reaches dispatchTransaction as a doc change.
      this._onSelection = () => this.refreshToolbar();
      document.addEventListener("selectionchange", this._onSelection);
    },

    updated() {
      // The editor's own subtree carries phx-update="ignore", but the hidden
      // input does not: the server can legitimately replace the document, and
      // when it does the editor has to follow.
      const value = this._input?.value;
      if (!this._view || value === undefined || this._written.has(value)) return;

      const doc = parseDoc(this._schema, value);

      // The input does not always hold a document: a rejected one comes back
      // as the raw text that was posted, so the writer can fix it. Rebuilding
      // the editor from that is not possible, and losing their work over it
      // would be worse than ignoring the round trip.
      if (!doc) {
        this.remember(value);
        return;
      }

      // Validation normalises, so the server's copy is rarely byte-identical
      // to what the editor wrote even when it says the same thing. Comparing
      // documents rather than text is what tells an echo from a replacement.
      if (doc.eq(this._view.state.doc)) {
        this.remember(value);
        return;
      }

      // Replacing the content through a transaction rather than building a
      // fresh EditorState: a new state starts with a default selection, so
      // the caret would jump to the top of the document every time the
      // server's normalisation differed from what the editor wrote. The
      // transaction maps the selection across, and stays out of the undo
      // history — it is not an edit anyone made.
      const { state } = this._view;
      const { from, to } = state.selection;
      const transaction = state.tr
        .replaceWith(0, state.doc.content.size, doc.content)
        .setMeta("addToHistory", false)
        .setMeta(REMOTE, true);

      // The replace spans the whole document, so every position falls inside
      // the deleted range and maps to its end. Mapping cannot preserve the
      // caret here; it has to be put back by hand, at the offsets it held.
      transaction.setSelection(selectionAt(transaction.doc, from, to));

      this.remember(value);
      this._view.dispatch(transaction);
    },

    destroyed() {
      this.el.removeEventListener("mousedown", this._onToolbar);
      if (this._onLinkKey) this._linkInput?.removeEventListener("keydown", this._onLinkKey);
      document.removeEventListener("selectionchange", this._onSelection);

      if (this._onFiles) {
        this._content?.removeEventListener("drop", this._onFiles);
        this._content?.removeEventListener("paste", this._onFiles);
      }

      this._view?.destroy();
    }
  });

export const Coelho = createCoelhoHook();
export default Coelho;
