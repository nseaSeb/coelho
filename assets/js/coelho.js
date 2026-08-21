import { createHook } from "@nseaprotector/acme-script";
import OrderedMap from "orderedmap";
import {
  Schema,
  Node as PMNode,
  DOMParser as PMDOMParser,
  DOMSerializer
} from "prosemirror-model";
import { EditorState, Selection, TextSelection } from "prosemirror-state";
import { EditorView } from "prosemirror-view";
import { keymap } from "prosemirror-keymap";
import {
  baseKeymap,
  toggleMark,
  setBlockType,
  wrapIn,
  lift,
  chainCommands,
  exitCode
} from "prosemirror-commands";
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

const ALIGNS = ["left", "center", "right", "justify"];

// Alignment is stored as an attribute and shown as a style, on both sides:
// the server renders the same `text-align` so what the writer sees is what
// the public page will carry.
const alignAttrs = (node, attrs = {}) =>
  ALIGNS.includes(node.attrs.align)
    ? { ...attrs, style: `text-align:${node.attrs.align}` }
    : attrs;

// The style wins, and the attribute is the fallback — but a style naming
// something that is not an alignment falls *through* to the attribute rather
// than ending the search, which is what Coelho.Schema.Default.align_of/1
// does. Stopping at the style would make the editor and the server read the
// same markup differently.
const readAlign = (dom) => {
  const styled = /text-align\s*:\s*([a-z]+)/i.exec(dom.getAttribute("style") ?? "");
  const declared = (dom.getAttribute("align") ?? "").trim().toLowerCase();

  return (
    [(styled?.[1] ?? "").toLowerCase(), declared].find((align) => ALIGNS.includes(align)) ?? null
  );
};

// Preview URLs live outside the document, keyed by attachment key.
const previewUrls = new Map();

export const setPreviewUrl = (key, url) => {
  if (key && url) previewUrls.set(key, url);
};

export const defaultNodeDOM = {
  paragraph: {
    toDOM: (node) => ["p", alignAttrs(node), 0],
    parseDOM: [{ tag: "p", getAttrs: (dom) => ({ align: readAlign(dom) }) }]
  },
  heading: {
    toDOM: (node) => ["h" + clampLevel(node.attrs.level), alignAttrs(node), 0],
    parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({
      tag: `h${level}`,
      getAttrs: (dom) => ({ level, align: readAlign(dom) })
    }))
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
    toDOM: (node) => ["li", alignAttrs(node), 0],
    parseDOM: [{ tag: "li", getAttrs: (dom) => ({ align: readAlign(dom) }) }],
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
    const { editorAttrs, ...rest } = spec;

    map = map.addToEnd(name, withEditorAttrs({ ...rest, ...(dom[name] ?? {}) }, editorAttrs));
  }

  return map;
};

// A node or mark spec may carry a class and extra DOM attributes declared
// once in Elixir. The class is applied on both sides, so the writer sees the
// class the public page will carry; the rest is the editor's alone. Wrapping
// toDOM here is what spares an application a custom hook written only to put
// a class on an element.
const withEditorAttrs = (spec, editorAttrs) => {
  if (!editorAttrs || !spec.toDOM) return spec;

  const toDOM = spec.toDOM;

  return {
    ...spec,
    toDOM: (nodeOrMark, ...rest) => mergeAttrs(toDOM(nodeOrMark, ...rest), editorAttrs)
  };
};

// A DOMOutputSpec is `[tag]`, `[tag, attrs, ...]`, `[tag, 0]` or
// `[tag, [childTag, ...]]`. The content hole is a number, and a nested
// element is an array — which `typeof` also calls "object", so the array has
// to be ruled out explicitly or `code_block`'s `["pre", ["code", {}, 0]]`
// gets spread into the attributes and the `<code>` disappears. Anything that
// is not an array of that shape (a DOM node, a plain string) is handed back
// untouched rather than guessed at.
const mergeAttrs = (out, editorAttrs) => {
  if (!Array.isArray(out) || typeof out[0] !== "string") return out;

  const [tag, ...rest] = out;
  const carriesAttrs =
    rest.length > 0 &&
    typeof rest[0] === "object" &&
    rest[0] !== null &&
    !Array.isArray(rest[0]);
  const attrs = { ...(carriesAttrs ? rest[0] : {}) };
  const tail = carriesAttrs ? rest.slice(1) : rest;

  for (const [name, value] of Object.entries(editorAttrs)) {
    attrs[name] = name === "class" && attrs.class ? `${attrs.class} ${value}` : value;
  }

  return [tag, attrs, ...tail];
};

// Grapheme clusters, the same unit `Coelho.Document.text_length/1` counts,
// so the editor's counter and the server's bound give the same number. Where
// Intl.Segmenter is missing the fallback counts code points, which differs
// only for combining sequences.
const countGraphemes =
  typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
    ? ((segmenter) => (text) => {
        let count = 0;
        for (const _ of segmenter.segment(text)) count += 1;
        return count;
      })(new Intl.Segmenter())
    : (text) => [...text].length;

// What the writer typed, and nothing else: no bullet, no blank line between
// paragraphs, no filename standing in for an attachment. A counter measured
// on the rendered text rejects a document the editor still shows as under
// the limit, with nothing on screen to explain the gap.
export const textLength = (document) => {
  const node = typeof document?.toJSON === "function" ? document.toJSON() : document;

  if (!node || typeof node !== "object") return 0;
  if (typeof node.text === "string") return countGraphemes(node.text);
  if (!Array.isArray(node.content)) return 0;

  return node.content.reduce((total, child) => total + textLength(child), 0);
};

// An editor carries the exported schema itself, or points at a
// `coelho_schema/1` rendered once for several of them to share.
//
// The shared one is read fresh every time, which is what lets a schema
// change reach an editor that does not carry its own — and the fingerprints
// have to agree, because an editor filtering its toolbar against one schema
// while building its document from another is a mismatch that shows up as
// buttons doing nothing rather than as an error.
const readSchema = (el) => {
  const src = el.dataset.coelhoSchemaSrc;

  if (!src) {
    if (!el.dataset.coelhoSchema) throw new Error("coelho: the editor carries no schema");
    return JSON.parse(el.dataset.coelhoSchema);
  }

  const shared = window.document.getElementById(src);

  if (!shared?.dataset.coelhoSchema) {
    throw new Error(`coelho: no <.coelho_schema id="${src}"> on the page`);
  }

  // The schema alone, not the schema and the toolbar: the shared element has
  // no toolbar of its own to fingerprint.
  if (shared.dataset.coelhoSchemaCheck !== el.dataset.coelhoSchemaCheck) {
    throw new Error(
      `coelho: the editor and <.coelho_schema id="${src}"> were given different schemas; ` +
        "pass the same document_schema to both"
    );
  }

  return JSON.parse(shared.dataset.coelhoSchema);
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

// What a block turns back into when its command is pressed a second time:
// whatever the schema says belongs where this block is, which is a paragraph
// in the schema that ships and need not be in yours.
const plainBlock = (state) => {
  const { $from } = state.selection;
  const parent = $from.node(-1);

  return (
    (parent && parent.contentMatchAt($from.index(-1)).defaultType) ||
    state.schema.nodes.paragraph
  );
};

// Pressing a block button again must undo it. Without this the command is
// simply not applicable once it has been applied — `setBlockType` answers
// false for a block that is already that type — so the button disables
// itself and there is no way back to a paragraph.
const toggleBlock = (type, attrs) => (state, dispatch, view) => {
  if (!blockActive(state, type, attrs)) return setBlockType(type, attrs)(state, dispatch, view);

  const plain = plainBlock(state);
  return Boolean(plain) && setBlockType(plain)(state, dispatch, view);
};

const toggleWrap = (type) => (state, dispatch, view) =>
  blockActive(state, type)
    ? lift(state, dispatch, view)
    : wrapIn(type)(state, dispatch, view);

const toggleList = (type, itemType) => (state, dispatch, view) =>
  itemType && blockActive(state, type)
    ? liftListItem(itemType)(state, dispatch, view)
    : wrapInList(type)(state, dispatch, view);

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
      return nodes.heading && toggleBlock(nodes.heading, { level: Number(options.level ?? 2) });
    case "paragraph":
      return nodes.paragraph && setBlockType(nodes.paragraph);
    case "code_block":
      return nodes.code_block && toggleBlock(nodes.code_block);
    case "blockquote":
      return nodes.blockquote && toggleWrap(nodes.blockquote);
    case "bullet_list":
      return nodes.bullet_list && toggleList(nodes.bullet_list, nodes.list_item);
    case "ordered_list":
      return nodes.ordered_list && toggleList(nodes.ordered_list, nodes.list_item);
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
// Only the attributes the command names are compared, never the whole set.
// `Node.hasMarkup` compares every attribute, so a schema that adds one the
// toolbar knows nothing about — `align`, say — makes every block button
// answer "not active" and stop toggling off. What the button asks is "is
// this a level 2 heading", not "is this a level 2 heading with nothing else
// set".
const hasMarkup = (node, type, attrs) =>
  node.type === type &&
  (!attrs || Object.entries(attrs).every(([name, value]) => node.attrs[name] === value));

const blockActive = (state, type, attrs) => {
  const { $from, node } = state.selection;

  if (node) return hasMarkup(node, type, attrs);

  // Anywhere above the cursor counts: a list and a quote can both be in
  // force at once, and a heading is still a heading when the whole document
  // is selected. Asking whether the selection *ends* inside the block, the
  // way the usual snippet does, answers no on a select-all.
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    if (hasMarkup($from.node(depth), type, attrs)) return true;
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

// Moving a document from one schema to another. `Node.fromJSON` is all or
// nothing — it throws on the *first* node, mark or attribute the new schema
// does not recognise — so using it here would answer a renamed mark by
// emptying the whole document. Going through the DOM is ProseMirror's own
// lenient path: what the new schema can parse it keeps, what it cannot it
// drops, and the text stays either way.
const reinterpret = (doc, from, to) => {
  const container = window.document.createElement("div");

  container.appendChild(
    DOMSerializer.fromSchema(from).serializeFragment(doc.content, { document: window.document })
  );

  return PMDOMParser.fromSchema(to).parse(container);
};

// -- Hook -------------------------------------------------------------------

// `nodes` and `marks` say how a node *looks*; `nodeViews` say how it
// *behaves* — drag handles on an image, a menu on an embed. Both are
// functions and neither can come from Elixir, which is why they are taken
// here rather than exported with the schema.
export const createCoelhoHook = ({ nodeViews = {}, ...dom } = {}) =>
  createHook({
    mounted(ctx) {
      const el = ctx.el;
      const input = document.getElementById(el.dataset.coelhoInput);
      const content = el.querySelector(".coelho-content");

      const schema = buildSchema(readSchema(el), dom);
      this._schema = schema;
      this._input = input;
      this._version = el.dataset.coelhoSchemaVersion;
      this._written = new Set();
      this._pending = new Map();

      this._maxlength = Number(el.dataset.coelhoMaxlength) || 0;
      this._counter = el.querySelector(".coelho-counter");
      this._count = el.querySelector("[data-coelho-count]");

      // Captured once, and deliberately not refreshed in updated(). The token
      // exists so the application can refuse a flush from before whatever it
      // just did — cancelling a draft re-renders the editors, and the ones
      // being torn down would otherwise push back the content the cancel
      // threw away. An editor that read the *new* token on its way out would
      // have its stale content accepted, which is the bug the token is for.
      this._flushEvent = el.dataset.coelhoFlushEvent;
      this._flushToken = el.dataset.coelhoFlushToken ?? null;
      this._name = input?.name ?? null;

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
        nodeViews,
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
        const snapshot = this._view.state.doc.toJSON();
        const json = JSON.stringify(snapshot);
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
        this.refreshCount(snapshot);
      };

      // The same unit `Coelho.Document.text_length/1` counts, so the number
      // on screen and the number the schema's `max_text_length` is checked
      // against are the same number. Counting the rendered text instead
      // would refuse a document the editor still shows as under the limit,
      // with nothing on screen to explain the gap.
      this.refreshCount = (snapshot) => {
        if (!this._count) return;

        const length = textLength(snapshot ?? this._view.state.doc.toJSON());

        this._count.textContent = String(length);
        this._counter?.classList.toggle("coelho-over", this._maxlength > 0 && length > this._maxlength);
      };

      // A schema changed under a mounted editor used to go unnoticed: the
      // container carries phx-update="ignore", so nothing about the new
      // vocabulary — its node types, its marks, the classes they carry —
      // reached the view, and the writer went on seeing the old one. The
      // server stamps a fingerprint on the hook's own element, which is not
      // ignored, and this follows it.
      //
      // The document is re-parsed against the new schema, so a node it no
      // longer knows goes; the undo history is dropped with the old schema,
      // because it is a history of edits the new one may have no words for.
      this.rebuild = () => {
        const rebuilt = buildSchema(readSchema(el), dom);
        const doc = reinterpret(this._view.state.doc, this._schema, rebuilt);

        this._schema = rebuilt;
        this._version = el.dataset.coelhoSchemaVersion;
        this._view.updateState(
          EditorState.create({
            doc,
            plugins: [history(), keymap(buildKeymap(rebuilt)), keymap(baseKeymap)]
          })
        );

        this.findLinkField();
        this.refreshToolbar();
        // The input still holds the document as it was written under the old
        // schema. Leaving it there would show one thing and post another, and
        // the next keystroke would post whatever the rebuild had dropped.
        this.syncInput();
      };

      const buttonIn = (event) => {
        const button = event.target.closest("[data-coelho-command]");
        return button && el.contains(button) ? button : null;
      };

      this.runCommand = (button) => {
        const command = commandFor(button.dataset.coelhoCommand, schema, button.dataset);
        if (!command) return;

        command(this._view.state, this._view.dispatch, this._view);

        // Unless the command opened the field, which has just taken the focus
        // on purpose. Taking it back leaves the field on screen with the
        // caret still in the document, so what the writer types goes into
        // their text and Enter never reaches the field.
        if (!this._pendingField) this._view.focus();
      };

      // A mouse press runs the command *here*, at `mousedown`, because this
      // is the last moment the selection is still the writer's: preventing
      // the default keeps focus, but the browser moves the caret on mouseup
      // anyway, and a command reading the selection after that acts on the
      // wrong place. Only the primary button: a right-click opens a menu.
      this._onToolbarDown = (event) => {
        const button = buttonIn(event);
        if (!button || event.button !== 0) return;

        event.preventDefault();
        this.runCommand(button);
      };

      // A keyboard press produces a `click` and no `mousedown`, which is what
      // makes the toolbar reachable without a mouse. `detail` is the click
      // count — zero when no pointer was involved — so the browser says which
      // it was, and no flag has to be kept in step. Anything that leaves a
      // flag behind would swallow the next keyboard press of the same button:
      // releasing off the button, a right-click, or a command that disables
      // the button it was on, none of which produce a `click` at all.
      this._onToolbar = (event) => {
        const button = buttonIn(event);
        if (!button || event.detail !== 0) return;

        event.preventDefault();
        this.runCommand(button);
      };

      el.addEventListener("mousedown", this._onToolbarDown);
      el.addEventListener("click", this._onToolbar);

      // Re-found rather than captured once: the toolbar's id carries the
      // schema fingerprint, so a schema change makes LiveView replace the
      // whole toolbar — and with it the link field. Holding the node from
      // mount would leave `openField` focusing something no longer in the
      // document, with the visible field carrying no key handler and the
      // button appearing to do nothing at all.
      this.findLinkField = () => {
        if (this._onLinkKey) this._linkInput?.removeEventListener("keydown", this._onLinkKey);

        this._linkZone = el.querySelector("[data-coelho-link-zone]");
        this._linkInput = el.querySelector("[data-coelho-link-input]");

        if (this._linkInput && this._onLinkKey) {
          this._linkInput.addEventListener("keydown", this._onLinkKey);
        }
      };

      this._linkZone = el.querySelector("[data-coelho-link-zone]");
      this._linkInput = el.querySelector("[data-coelho-link-input]");

      // One field, whatever asked for it. What it does on Enter is decided
      // when it opens, because the selection is what says what to act on and
      // a field that took the focus would lose the answer.
      this.openField = ({ value, label, apply, type = "text", placeholder = "" }) => {
        if (!this._linkInput) return;

        this._pendingField = apply;
        this._linkZone.hidden = false;
        this._linkInput.value = value ?? "";
        this._linkInput.setAttribute("aria-label", label);
        // The field serves more than links, so what it asks for changes with
        // it: a caption left under `type="url"` matches `:invalid` while
        // being perfectly good, and a phone offers a keyboard with no space
        // key for it.
        this._linkInput.type = type;
        this._linkInput.placeholder = placeholder;
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
          placeholder: "Describe this attachment",
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
            type: "url",
            placeholder: "https://…",
            apply: this.applyLink({ from, to })
          });
        } else if (existing) {
          this.openField({
            value: existing.href,
            label: "Link address",
            type: "url",
            placeholder: "https://…",
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

    updated(ctx) {
      if (!this._view) return;

      // A new vocabulary is not a new document: rebuilding reads the input
      // itself, so the value sync below has nothing left to do.
      if (ctx.el.dataset.coelhoSchemaVersion !== this._version) {
        this.rebuild();
        return;
      }

      // The editor's own subtree carries phx-update="ignore", but the hidden
      // input does not: the server can legitimately replace the document, and
      // when it does the editor has to follow.
      const value = this._input?.value;
      if (value === undefined || this._written.has(value)) return;

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

    destroyed(ctx) {
      // The editor writes into its hidden input and lets phx-change carry it,
      // so a phx-debounce can still be holding the last edit when the element
      // goes. LiveView cancels the timer with the element and the change is
      // simply lost — the writer's last few characters, gone, with nothing to
      // show it happened. This is the way out.
      if (this._flushEvent && this._view) {
        // `pushEvent` answers with a promise, and rejects it rather than
        // throwing when the socket has gone — a full page navigation destroys
        // every hook on the way out. A try/catch never sees that, and the
        // rejection nobody handles is reported as an uncaught error, which is
        // exactly what a page's error reporting is watching for.
        Promise.resolve(
          ctx.push(this._flushEvent, {
            token: this._flushToken,
            name: this._name,
            document: this._view.state.doc.toJSON()
          })
        ).catch((error) => console.warn("coelho: could not flush on destroy", error));
      }

      this.el.removeEventListener("mousedown", this._onToolbarDown);
      this.el.removeEventListener("click", this._onToolbar);
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
