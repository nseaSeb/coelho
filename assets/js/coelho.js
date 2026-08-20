import { createHook } from "@nseaprotector/acme-script";
import OrderedMap from "orderedmap";
import { Schema, Node as PMNode } from "prosemirror-model";
import { EditorState } from "prosemirror-state";
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

const askForHref = (view) => {
  // An application that wants its own link UI listens for this and calls
  // `event.detail.apply(href)`; nothing listening falls back to a prompt.
  let handled = false;
  const event = new CustomEvent("coelho:link", {
    bubbles: true,
    cancelable: true,
    detail: {
      apply: (href) => {
        handled = true;
        if (href) applyLink(view, href);
      }
    }
  });

  view.dom.dispatchEvent(event);
  if (!handled && !event.defaultPrevented) {
    const href = window.prompt("Link URL");
    if (href) applyLink(view, href);
  }
};

const applyLink = (view, href) => {
  const mark = view.state.schema.marks.link;
  if (mark) toggleMark(mark, { href })(view.state, view.dispatch);
  view.focus();
};

const commandFor = (name, schema, options) => {
  const { nodes, marks } = schema;

  switch (name) {
    case "bold":
    case "italic":
    case "strike":
    case "code":
      return marks[name] && toggleMark(marks[name]);
    case "link":
      return marks.link && ((state, dispatch, view) => (askForHref(view), true));
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

      const state = EditorState.create({
        doc: PMNode.fromJSON(schema, JSON.parse(input.value)),
        plugins: [history(), keymap(buildKeymap(schema)), keymap(baseKeymap)]
      });

      this._view = new EditorView(content, {
        state,
        dispatchTransaction: (transaction) => {
          this._view.updateState(this._view.state.apply(transaction));
          if (transaction.docChanged) this.syncInput();
        }
      });

      this.syncInput = () => {
        const json = JSON.stringify(this._view.state.doc.toJSON());
        // Remember what we wrote, so `updated()` can tell a server-driven
        // change from the echo of our own.
        this._lastWritten = json;
        if (input.value !== json) {
          input.value = json;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        }
        el.classList.toggle("coelho-empty", !this._view.state.doc.textContent);
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

      // Placeholder text is exposed for CSS rather than inserted into the
      // document: a placeholder node would be a node, and would end up
      // validated, stored and rendered.
      if (el.dataset.coelhoPlaceholder) {
        content.dataset.placeholder = el.dataset.coelhoPlaceholder;
      }

      this.insertAttachment = (nodeJSON, url) => {
        setPreviewUrl(nodeJSON.attrs?.key, url);
        const node = PMNode.fromJSON(this._schema, nodeJSON);
        this._view.dispatch(this._view.state.tr.replaceSelectionWith(node).scrollIntoView());
      };

      // The server owns storage, so the round trip is: files go up through
      // LiveView's own upload channel, the application consumes them and
      // pushes back the node to insert.
      ctx.handle("coelho:attachment", ({ node, url }) => this.insertAttachment(node, url));

      const uploadName = el.dataset.coelhoUpload;

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

      this._content = content;
      this.syncInput();
    },

    updated() {
      // The editor's own subtree carries phx-update="ignore", but the hidden
      // input does not: the server can legitimately replace the document, and
      // when it does the editor has to follow.
      const value = this._input?.value;
      if (!this._view || value === undefined || value === this._lastWritten) return;

      const doc = PMNode.fromJSON(this._schema, JSON.parse(value));
      const state = EditorState.create({ doc, plugins: this._view.state.plugins });
      this._view.updateState(state);
      this._lastWritten = value;
    },

    destroyed() {
      this.el.removeEventListener("mousedown", this._onToolbar);

      if (this._onFiles) {
        this._content?.removeEventListener("drop", this._onFiles);
        this._content?.removeEventListener("paste", this._onFiles);
      }

      this._view?.destroy();
    }
  });

export const Coelho = createCoelhoHook();
export default Coelho;
