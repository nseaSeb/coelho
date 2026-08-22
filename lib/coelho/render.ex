defmodule Coelho.Render do
  @moduledoc """
  Turns a validated document into HTML.

  Rendering is driven by the `:render` field of each node and mark spec,
  which takes one of three forms:

    * `nil` — the node contributes nothing but its children
    * `{tag, attrs}` — an element, where `attrs` is either a static list of
      `{name, value}` pairs or a function of the node returning such a list
    * `fun/2` — full control, receiving the node and its already rendered
      children as iodata
    * `fun/3` — the same, plus the `:context` given to this render call

  A spec's `:class` is merged into the `{tag, attrs}` form, after whatever
  class the attributes already carry. A render function is not touched: it
  builds the whole element itself, so it applies its own class.

  Callers can override any of them per call through the `:nodes` and
  `:marks` options, which is how a Phoenix application injects its own
  markup — mentions, embeds, syntax highlighted code — without changing what
  is stored.

  The `:context` option carries whatever the render functions need from the
  application and cannot know on their own. Attachments use it to turn a
  stored key into a URL at render time, which is what lets signed and
  expiring URLs work at all — see `Coelho.Attachments`.

  ## What is escaped

  Two things, and between them they are the safety guarantee of the package:

    * the text of every text node, through `escape/1`
    * every attribute value, through `escape/1` before it is quoted

  `&`, `<`, `>`, `"` and `'` all become entities. Nothing a writer typed is
  ever emitted as markup, because a document holds no markup to begin with —
  it holds a tree, and this builds the tags.

  What escaping cannot cover is a value that is perfectly quoted and still
  dangerous: `javascript:` in an `href` executes however well it is escaped.
  `safe_url/1` is for those, and the shipped renderers put every URL through
  it.

  Two things are *not* escaped, and both are the schema author's to get
  right: tag names, and attribute *names*. Both come from the schema, which
  is code.

  `nil` renders as nothing rather than raising: it is what a nullable column
  holds and what both stored types cast an absent document to, so a template
  writing `to_safe_html(@post.body)` should not have to guard it.

  Only validated documents should be rendered. Rendering does not re-check
  the document against the schema; it trusts `Coelho.Document.validate/2`
  to have run, and raises on anything it does not recognise. For a document
  read back out of storage, where that is not a safe assumption, put it
  through `Coelho.Document.sanitize/2` first.
  """

  alias Coelho.Schema
  alias Coelho.Schema.Attr

  @type opts :: [
          nodes: %{optional(atom()) => term()},
          marks: %{optional(atom()) => term()},
          context: term()
        ]

  @doc """
  Renders a document to iodata.
  """
  @spec to_iodata(map(), Schema.t(), opts()) :: iodata()
  def to_iodata(document, %Schema{} = schema, opts \\ []) do
    state = %{
      nodes: Keyword.get(opts, :nodes, %{}),
      marks: Keyword.get(opts, :marks, %{}),
      context: Keyword.get(opts, :context, %{})
    }

    Coelho.Telemetry.span(
      [:coelho, :render],
      fn -> %{schema: Schema.fingerprint(schema)} end,
      fn -> render_node(document, schema, state) end,
      &%{bytes: IO.iodata_length(&1)}
    )
  end

  @doc """
  Renders a document to an HTML string.
  """
  @spec to_html(map(), Schema.t(), opts()) :: String.t()
  def to_html(document, %Schema{} = schema, opts \\ []) do
    document |> to_iodata(schema, opts) |> IO.iodata_to_binary()
  end

  @doc """
  Renders a document where only inline elements are legal.

  ## Why this exists

  A `<p>` inside a `<p>` is not nested by the browser, it is **closed** by
  it. Put `to_html/3` inside a paragraph or a span — a news banner, the
  detail panel of a map marker, a truncated card excerpt — and four things
  happen, none of them reported:

    * the enclosing paragraph ends where the document's first one begins, so
      every class on it stops applying from there
    * an empty paragraph appears where the enclosing one was reopened
    * a block element inside a `<span>` breaks the line, whatever the span's
      layout was for
    * and the words of two paragraphs run together, because the tags that
      separated them are gone

  The last is the one nobody sees, because it looks like text.

  ## What it guarantees

  **The output holds nothing that is illegal in an inline context.** That is
  the whole contract, and everything else follows from it without a judgement
  call:

    * marks stay — `<strong>`, `<em>`, `<code>`, `<a>` are inline
    * `<img>` and `<br>` stay
    * every block is unwrapped to its children: a heading contributes its
      words, a list its items, a code block its text. A block that had a tag
      loses the tag, which is what "inline" means
    * a node whose inline form is not simply its children says so, with
      `:render_inline` in its spec — an attachment renders its image and its
      caption's text rather than the `<figure>` it is on a page of its own
    * a node with no inline equivalent at all contributes nothing. A
      horizontal rule is the example, and it is mechanical rather than a
      policy

  Empty contributions are dropped rather than separated, which is not a mode:
  it is what joining correctly means.

  ## The separator is yours

  Only the caller knows whether its container can take a line break. A map
  bubble wants `:br`; a fixed-height banner wants `:space`, and so does a
  truncated excerpt.

      Coelho.Render.to_inline_html(document, schema, separator: :br)

  `:space` is the default because the two mistakes do not cost the same. A
  space where a break was wanted puts two sentences on one line, which reads.
  A break where a space was wanted grows the caller's box and breaks their
  layout.

  A separator of your own is escaped, because a value that reached this from
  data would otherwise be markup. Pass `{:safe, iodata}` to say it is not.

  It governs the boundaries between blocks and nothing else. A hard break the
  writer typed is content, and still renders as `<br>` under `:space` — it is
  not a seam this put there, and dropping it would be dropping something
  someone wrote.
  """
  @spec to_inline_html(map(), Schema.t(), opts()) :: String.t()
  def to_inline_html(document, %Schema{} = schema, opts \\ []),
    do: document |> to_inline_iodata(schema, opts) |> IO.iodata_to_binary()

  @doc """
  `to_inline_html/3` in the shape a template will not escape again.

  The same reasoning as `to_safe_html/3`: having removed the need to remember
  `raw/1` in one place, this does not reintroduce it in the other.
  """
  @spec to_safe_inline_html(map(), Schema.t(), opts()) :: {:safe, iodata()}
  def to_safe_inline_html(document, %Schema{} = schema, opts \\ []),
    do: {:safe, to_inline_iodata(document, schema, opts)}

  @doc """
  `to_inline_html/3` as iodata.
  """
  @spec to_inline_iodata(map(), Schema.t(), opts()) :: iodata()
  def to_inline_iodata(document, %Schema{} = schema, opts \\ []) do
    state = %{
      nodes: Keyword.get(opts, :nodes, %{}),
      marks: Keyword.get(opts, :marks, %{}),
      context: Keyword.get(opts, :context, %{}),
      separator: separator(Keyword.get(opts, :separator, :space))
    }

    document |> inline_node(schema, state) |> elem(1)
  end

  defp separator(:space), do: " "
  defp separator(:br), do: "<br>"
  defp separator({:safe, iodata}), do: iodata
  defp separator(other) when is_binary(other), do: escape(other)

  defp separator(other) do
    raise ArgumentError,
          "separator must be :space, :br, a string, or {:safe, iodata}, got #{inspect(other)}"
  end

  # Answers `{block?, iodata}`: whether this node was a block, which is what
  # decides where a separator goes, and what it contributed.
  defp inline_node(nil, _schema, _state), do: {false, []}

  defp inline_node(%{"type" => type} = node, schema, state) when is_binary(type) do
    spec = fetch_node_spec!(schema, type)

    cond do
      # Text has no inline form of its own, and going through `render_node/3`
      # is what honours a caller's override of it — which the block renderer
      # goes out of its way not to short circuit for exactly this reason.
      spec.text ->
        {false, render_node(node, schema, state)}

      # The caller's override, then `:render_inline`, then unwrapping: the
      # same order of who decides as the block renderer. It applies to an
      # inline node too, which is where `:render_inline` would otherwise be
      # unreachable — an inline-grouped node whose ordinary render is a
      # block-ish wrapper has nowhere else to say what it is inline.
      render = Map.get(state.nodes, spec.name) || spec.render_inline ->
        body =
          render_with(node, spec, render, inline_children(node, schema, state), state.context)

        {not spec.inline, if(spec.inline, do: apply_marks(body, node, schema, state), else: body)}

      spec.inline ->
        {false, render_node(node, schema, state)}

      true ->
        {true, inline_children(node, schema, state)}
    end
  end

  defp inline_node(node, _schema, _state) do
    raise ArgumentError, "cannot render #{inspect(node)}: expected a node with a string type"
  end

  # A separator sits between two contributions when either side came from a
  # block, and nowhere else: `<p>a</p><p>b</p>` needs one, `a<img>b` does not.
  # Empty contributions are dropped first, so a node that renders to nothing —
  # a horizontal rule — leaves no separator behind it.
  defp inline_children(node, schema, state) do
    node
    |> Map.get("content", [])
    |> Enum.map(&inline_node(&1, schema, state))
    |> Enum.reject(fn {_block?, iodata} -> blank?(iodata) end)
    |> join(state.separator)
  end

  # Whether a rendered child came to nothing, answered at the first byte
  # rather than by measuring the whole subtree — which, asked at every level,
  # walks the render once per level of depth.
  # Written as clauses rather than as `Enum.all?`: an iolist may be improper
  # — `["" | inner]` is valid iodata and a render override is free to build
  # one — and `Enum.all?` refuses those, where `IO.iodata_length/1` did not.
  defp blank?([]), do: true
  defp blank?([head | tail]), do: blank?(head) and blank?(tail)
  defp blank?(binary) when is_binary(binary), do: binary == ""
  defp blank?(byte) when is_integer(byte), do: false

  defp join([], _separator), do: []
  defp join([{_block?, iodata}], _separator), do: iodata

  defp join([{block?, iodata} | rest], separator) do
    [{next_block?, _} | _] = rest
    tail = join(rest, separator)

    if block? or next_block?, do: [iodata, separator, tail], else: [iodata, tail]
  end

  @doc """
  Renders a validated document as `{:safe, iodata}`.

  What `to_html/3` renders, in the shape a template will not escape again.
  `to_html/3` answers a `String.t()`, which HEEx and `Phoenix.HTML` treat as
  text — correctly, since they cannot know it is markup — so the caller has
  to remember `raw/1`, and has two ways to get it wrong: forget it, and the
  document is shown as its own source; reach for it somewhere else, and
  something that should have been escaped no longer is.

  For a package whose argument is that rendering is safe by construction,
  that is the last link left to the caller. This closes it:

      <div class="prose">{Coelho.to_safe_html(@post.body)}</div>

  The `{:safe, iodata}` pair is what `Phoenix.HTML.Engine` unwraps directly,
  so this costs no dependency — Coelho has none for HTML, and does not
  acquire one here. There is no `Phoenix.HTML.Safe` implementation to go with
  it because there is nothing to implement it *for*: a document is a bare
  map, deliberately, and an implementation for `Map` would apply to every map
  in the application.

  It renders the same iodata `to_iodata/3` builds, so the escaping guarantees
  above hold unchanged.
  """
  @spec to_safe_html(map(), Schema.t(), opts()) :: {:safe, iodata()}
  def to_safe_html(document, %Schema{} = schema, opts \\ []),
    do: {:safe, to_iodata(document, schema, opts)}

  @doc """
  Folds a document into any term at all.

  `to_html/3` and `to_iodata/3` answer one question — what does this look
  like on a web page — and answer it in iodata, which is the wrong shape for
  every other target. An invoice rendered through a typesetter, a search
  index, a word count per heading, a summary of the links a document
  contains: each of those is a fold over the same tree, and reimplementing
  the traversal per target is how a consumer ends up quietly disagreeing
  with the schema about what a document may hold.

  Two callbacks, and the accumulator is whatever they return:

    * `:node` — `fn node, children -> term end`, where `children` is the
      list of what this node's children folded to, in order
    * `:text` — `fn text, marks -> term end`, where `marks` is the node's
      marks, resolved against the schema, in the schema's declaration order.
      Leave it out and text nodes go through `:node` with no children.

  Either callback may take a third argument, which receives the `:context`
  option, exactly as the render functions do.

  The point of returning a term rather than iodata is that a target with its
  own escaping rules — a typesetting language, a template engine — can hand
  back a list of maps and let its own encoder do the quoting. Nothing the
  writer typed is ever concatenated into a string that something downstream
  will interpret as code.

      Coelho.Render.reduce(document, schema, %{
        text: fn text, marks -> %{"text" => text, "marks" => Enum.map(marks, & &1["type"])} end,
        node: fn node, children -> %{"block" => node["type"], "children" => children} end
      })

  Like `to_iodata/3`, this trusts the document: an unknown node or mark type
  raises rather than being skipped. Fold a validated document, or one that
  has been through `Coelho.Document.sanitize/2`.
  """
  @type callbacks :: %{
          required(:node) => (map(), [term()] -> term()) | (map(), [term()], term() -> term()),
          optional(:text) =>
            (String.t(), [map()] -> term()) | (String.t(), [map()], term() -> term())
        }

  @spec reduce(map(), Schema.t(), callbacks(), opts()) :: term()
  def reduce(document, %Schema{} = schema, callbacks, opts \\ []) do
    state = %{
      node: Map.fetch!(callbacks, :node),
      text: Map.get(callbacks, :text),
      context: Keyword.get(opts, :context, %{})
    }

    reduce_node(document, schema, state)
  end

  defp reduce_node(%{"type" => type} = node, schema, state) when is_binary(type) do
    spec = fetch_node_spec!(schema, type)

    if spec.text and state.text != nil do
      call(state.text, text_of(node), resolved_marks(node, schema), state.context)
    else
      children = node |> Map.get("content", []) |> Enum.map(&reduce_node(&1, schema, state))
      call(state.node, node, children, state.context)
    end
  end

  defp reduce_node(node, _schema, _state) do
    raise ArgumentError, "cannot fold #{inspect(node)}: expected a node with a string type"
  end

  defp call(fun, first, second, _context) when is_function(fun, 2), do: fun.(first, second)

  defp call(fun, first, second, context) when is_function(fun, 3),
    do: fun.(first, second, context)

  # Resolving each mark is what makes the mark list worth passing separately:
  # the caller gets the marks the *schema* knows, in the order the schema
  # declares them, and learns about one it does not know here rather than by
  # silently omitting it from the output. Validation already leaves them in
  # that order; sorting again is what lets the promise hold for a document
  # that came from somewhere else.
  defp resolved_marks(node, schema) do
    node
    |> Map.get("marks", [])
    |> Enum.map(fn %{"type" => type} = mark ->
      {Schema.mark_index(schema, fetch_mark_spec!(schema, type).name), mark}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Reads an attribute out of a node or a mark, falling back to a default.

  An attribute sitting at its schema default is not stored — see
  `Coelho.Document.canonical/1` for why — so a renderer must supply the
  default rather than read the key and hope. This is the one place that
  knows the shape of `"attrs"`.

  The default to pass is **the schema's**, not one chosen here: a heading
  stored with no `"level"` is a heading at whatever `:level` declares as its
  default, and a renderer answering something else prints a document the
  editor drew differently. Where the schema is at hand, read it from there
  rather than writing the number twice:

      level = Render.attr(node, "level", Schema.node_spec(schema, :heading).attrs.level.default)

  """
  @spec attr(map(), String.t(), term()) :: term()
  def attr(node, name, default \\ nil) do
    case Map.get(node, "attrs") do
      attrs when is_map(attrs) -> Map.get(attrs, name, default)
      _other -> default
    end
  end

  @doc """
  Escapes text for inclusion in HTML, attribute values included.

  Both halves of what an element carries go through this: the text of a text
  node, and every attribute value, escaped in `attributes/1` before it is
  quoted. `&`, `<`, `>`, `"` and `'` all become entities, which is what makes
  an attribute value safe inside either quoting style and text safe outside
  a tag.

  What escaping does not cover, and what `safe_url/1` exists for, is a value
  that is correctly quoted and still dangerous — a `javascript:` URL in an
  `href`.
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text), do: escape(text, text, 0, 0, [])

  # One pass over the bytes, copying the stretches between the five
  # characters that have to change, rather than five passes each building a
  # binary for the next one to throw away — this runs on every text node and
  # on every attribute value of every render. Matching byte by byte is safe
  # for the same reason it is fast: all five are ASCII, and no byte of a
  # multi-byte UTF-8 character is ever below 128.
  #
  # Text that escapes to itself is handed back as it came, unchopped and
  # uncopied, which is what most text does.
  defp escape(<<>>, original, 0, _len, []), do: original

  defp escape(<<>>, original, skip, len, acc),
    do: IO.iodata_to_binary([acc | [binary_part(original, skip, len)]])

  defp escape(<<char, rest::binary>>, original, skip, len, acc)
       when char in [?&, ?<, ?>, ?", ?'] do
    escape(rest, original, skip + len + 1, 0, [
      acc,
      binary_part(original, skip, len),
      entity(char)
    ])
  end

  defp escape(<<_char, rest::binary>>, original, skip, len, acc),
    do: escape(rest, original, skip, len + 1, acc)

  defp entity(?&), do: "&amp;"
  defp entity(?<), do: "&lt;"
  defp entity(?>), do: "&gt;"
  defp entity(?"), do: "&quot;"
  defp entity(?\'), do: "&#39;"

  @doc """
  Returns a URL fit to be emitted, or `nil` for one that is not.

  Validation already rejects unsafe URLs on the way in, but stored documents
  are not re-validated on the way out — `Coelho.Ecto.Type` deliberately trusts
  what is in the column. A row written before the schema tightened, by
  a direct database write, or under a looser custom schema, would otherwise
  put `javascript:` straight into an `href`. Escaping does not help there:
  the value is quoted correctly and still executes.

  Attributes built with this return `nil` and are dropped, so a suspect link
  renders as an `<a>` without an `href` rather than as a live one.
  """
  @spec safe_url(term()) :: String.t() | nil
  def safe_url(url) when is_binary(url) do
    case Attr.validate(:safe_url, url) do
      :ok -> url
      {:error, _reason} -> nil
    end
  end

  def safe_url(_url), do: nil

  @doc """
  Builds an element from a tag, an attribute list and rendered children.
  """
  @spec tag(String.t(), [{String.t(), term()}], iodata()) :: iolist()
  def tag(name, attrs, inner) do
    ["<", name, attributes(attrs), ">", inner, "</", name, ">"]
  end

  # The elements HTML itself closes. Anything else needs a closing tag, even
  # when the node has no children: `<span class="mention">` on its own
  # swallows the rest of the paragraph in the browser's parser, and a schema
  # extension reaching for a `void: true` inline node is exactly how that
  # happens.
  @html_void ~w(area base br col embed hr img input link meta param source track wbr)

  @doc """
  Builds a childless element, self-closing only if HTML says it is.
  """
  @spec void_tag(String.t(), [{String.t(), term()}]) :: iolist()
  def void_tag(name, attrs) when name in @html_void,
    do: ["<", name, attributes(attrs), ">"]

  def void_tag(name, attrs), do: tag(name, attrs, [])

  defp attributes(attrs) do
    Enum.map(attrs, fn
      {_name, nil} -> []
      {_name, false} -> []
      {name, true} -> [" ", name]
      {name, value} -> [" ", name, "=\"", escape(to_string(value)), "\""]
    end)
  end

  # -- Nodes ----------------------------------------------------------------

  # Every node, the text node included, goes through the same path: resolve
  # the spec, take the override if the caller supplied one, then wrap. Short
  # circuiting on `"type" => "text"` before consulting the schema would make
  # the text node the one node no caller can override.
  # A nullable column holds `nil`, and `nil` is what `Coelho.Ecto.Type` and
  # `Coelho.Ash.Type` both cast an absent document to. Rendering it as
  # nothing is the only answer that lets `to_safe_html(@post.body)` be
  # written straight into a template, which is the whole point of that
  # function.
  defp render_node(nil, _schema, _state), do: []

  defp render_node(%{"type" => type} = node, schema, state) do
    spec = fetch_node_spec!(schema, type)
    render = Map.get(state.nodes, spec.name, spec.render)

    inner =
      if spec.text, do: node |> text_of() |> escape(), else: children(node, schema, state)

    node
    |> render_with(spec, render, inner, state.context)
    |> apply_marks(node, schema, state)
  end

  defp text_of(node) do
    case Map.get(node, "text") do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp render_with(node, spec, render, inner, context) do
    case render do
      nil ->
        inner

      fun when is_function(fun, 2) ->
        fun.(node, inner)

      fun when is_function(fun, 3) ->
        fun.(node, inner, context)

      {tag, attrs} when spec.void ->
        void_tag(resolve_tag(tag, node), element_attrs(attrs, node, spec, context))

      {tag, attrs} ->
        tag(resolve_tag(tag, node), element_attrs(attrs, node, spec, context), inner)
    end
  end

  # The tag may be a function of the node, for an element whose *name* is
  # what an attribute decides — a heading, whose level is its tag. Written as
  # a render function instead, such a node would build its whole element and
  # so reach neither `:class` nor an attribute's `:render_as`.
  #
  # Nothing downstream escapes a tag name, so a function that builds one out
  # of an attribute owes the same bounding a `{:style, …}` attribute owes:
  # a stored document is not re-validated on the way out.
  defp resolve_tag(tag, node) when is_function(tag, 1), do: tag.(node)
  defp resolve_tag(tag, _node) when is_binary(tag), do: tag

  # What the element carries: what the spec's `:render` asked for, then what
  # each attribute's `:render_as` makes of the value, then the spec's
  # `:class`. All three merge into one `class` and one `style` rather than
  # repeating the attribute, which the browser would resolve by keeping the
  # first and dropping the rest.
  defp element_attrs(attrs, node, spec, context) do
    attrs
    |> resolve_attrs(node, context)
    |> merge_attrs(attr_dom(node, spec.attrs))
    |> with_class(spec.class)
  end

  # An attribute renders itself only when it says how. The value is checked
  # again here rather than trusted: validation bounded it on the way in, and
  # a row written under a looser schema still renders through this.
  defp attr_dom(node, attrs) do
    Enum.flat_map(attrs, fn {name, attr} ->
      # The default, not `nil`: an attribute sitting at its schema default is
      # not stored, so reading the key and hoping would leave a `render_as`
      # with a default of its own rendering nothing here while ProseMirror,
      # which fills defaults in, renders it in the editor.
      case {attr.render_as, attr(node, Atom.to_string(name), attr.default)} do
        {nil, _value} ->
          []

        {{:class, classes}, value} ->
          case Map.fetch(classes, value) do
            {:ok, class} -> [{"class", class}]
            :error -> []
          end

        {{:style, property}, value} when is_binary(value) ->
          if value in Attr.render_values(attr),
            do: [{"style", property <> ":" <> value}],
            else: []

        {{:style, _property}, _value} ->
          []
      end
    end)
  end

  defp merge_attrs(attrs, []), do: attrs

  # Merged into the list held backwards, so a new attribute is a prepend
  # rather than a copy of everything before it, and the order the element
  # carries is the order it was built in.
  defp merge_attrs(attrs, additions) do
    additions
    |> Enum.reduce(Enum.reverse(attrs), fn {name, value}, acc ->
      prepend_attr(acc, name, value)
    end)
    |> Enum.reverse()
  end

  # `class` and `style` accumulate — two attributes may each contribute one,
  # and a spec's `:render` may already have put one there. Anything else is
  # a single value and the later one wins.
  @separators %{"class" => " ", "style" => ";"}

  # On the list held backwards, which is why the new attribute is prepended:
  # `merge_attrs/2` reverses on the way in and on the way out, so this is the
  # end of the element. Nothing else may call it on a forward list.
  defp prepend_attr(attrs, name, value) do
    case {List.keyfind(attrs, name, 0), Map.get(@separators, name)} do
      {nil, _separator} ->
        [{name, value} | attrs]

      {{_name, existing}, separator}
      when is_binary(existing) and existing != "" and is_binary(separator) ->
        List.keyreplace(attrs, name, 0, {name, existing <> separator <> value})

      {_found, _separator} ->
        List.keyreplace(attrs, name, 0, {name, value})
    end
  end

  # A spec's `:class` is applied on both sides — here, and in the browser
  # through the exported schema — so the writer sees the class the public
  # page will carry. Declaring it twice is what lets the two drift, so it is
  # declared once. A render function takes over the whole element, so it is
  # the one form this cannot reach: say so rather than half apply it.
  defp with_class(attrs, nil), do: attrs
  defp with_class(attrs, class), do: merge_attrs(attrs, [{"class", class}])

  defp children(node, schema, state) do
    node
    |> Map.get("content", [])
    |> Enum.map(&render_node(&1, schema, state))
  end

  # -- Marks ----------------------------------------------------------------

  # The first mark of the list ends up outermost, matching the order
  # ProseMirror serialises them in.
  defp apply_marks(inner, node, schema, state) do
    node
    |> Map.get("marks", [])
    |> Enum.reverse()
    |> Enum.reduce(inner, fn mark, acc -> render_mark(mark, acc, schema, state) end)
  end

  defp render_mark(%{"type" => type} = mark, inner, schema, state) do
    spec = fetch_mark_spec!(schema, type)

    case Map.get(state.marks, spec.name, spec.render) do
      nil ->
        inner

      fun when is_function(fun, 2) ->
        fun.(mark, inner)

      fun when is_function(fun, 3) ->
        fun.(mark, inner, state.context)

      {tag, attrs} ->
        tag(
          resolve_tag(tag, mark),
          element_attrs(attrs, mark, spec, state.context),
          inner
        )
    end
  end

  defp resolve_attrs(attrs, node, _context) when is_function(attrs, 1), do: attrs.(node)
  defp resolve_attrs(attrs, node, context) when is_function(attrs, 2), do: attrs.(node, context)
  defp resolve_attrs(attrs, _node, _context) when is_list(attrs), do: attrs

  defp fetch_node_spec!(schema, type) do
    case Schema.fetch_node_spec(schema, type) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "cannot render unknown node type #{inspect(type)}"
    end
  end

  defp fetch_mark_spec!(schema, type) do
    case Schema.fetch_mark_spec(schema, type) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "cannot render unknown mark type #{inspect(type)}"
    end
  end
end
