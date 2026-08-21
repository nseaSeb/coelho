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

  Only validated documents should be rendered. Rendering does not re-check
  the document against the schema; it trusts `Coelho.Document.validate/2`
  to have run, and raises on anything it does not recognise. For a document
  read back out of storage, where that is not a safe assumption, put it
  through `Coelho.Document.sanitize/2` first.
  """

  alias Coelho.Schema
  alias Coelho.Schema.{Attr, MarkSpec, NodeSpec}

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

    render_node(document, schema, state)
  end

  @doc """
  Renders a document to an HTML string.
  """
  @spec to_html(map(), Schema.t(), opts()) :: String.t()
  def to_html(document, %Schema{} = schema, opts \\ []) do
    document |> to_iodata(schema, opts) |> IO.iodata_to_binary()
  end

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
  def escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

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
        void_tag(tag, with_class(resolve_attrs(attrs, node, context), spec.class))

      {tag, attrs} ->
        tag(tag, with_class(resolve_attrs(attrs, node, context), spec.class), inner)
    end
  end

  # A spec's `:class` is applied on both sides — here, and in the browser
  # through the exported schema — so the writer sees the class the public
  # page will carry. Declaring it twice is what lets the two drift, so it is
  # declared once. A render function takes over the whole element, so it is
  # the one form this cannot reach: say so rather than half apply it.
  defp with_class(attrs, nil), do: attrs

  defp with_class(attrs, class) do
    case List.keyfind(attrs, "class", 0) do
      {_key, existing} when is_binary(existing) and existing != "" ->
        List.keyreplace(attrs, "class", 0, {"class", existing <> " " <> class})

      nil ->
        attrs ++ [{"class", class}]

      _blank ->
        List.keyreplace(attrs, "class", 0, {"class", class})
    end
  end

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
        tag(tag, with_class(resolve_attrs(attrs, mark, state.context), spec.class), inner)
    end
  end

  defp resolve_attrs(attrs, node, _context) when is_function(attrs, 1), do: attrs.(node)
  defp resolve_attrs(attrs, node, context) when is_function(attrs, 2), do: attrs.(node, context)
  defp resolve_attrs(attrs, _node, _context) when is_list(attrs), do: attrs

  defp fetch_node_spec!(schema, type) do
    with {:ok, name} <- Schema.resolve_node_name(schema, type),
         %NodeSpec{} = spec <- Schema.node_spec(schema, name) do
      spec
    else
      _ -> raise ArgumentError, "cannot render unknown node type #{inspect(type)}"
    end
  end

  defp fetch_mark_spec!(schema, type) do
    with {:ok, name} <- Schema.resolve_mark_name(schema, type),
         %MarkSpec{} = spec <- Schema.mark_spec(schema, name) do
      spec
    else
      _ -> raise ArgumentError, "cannot render unknown mark type #{inspect(type)}"
    end
  end
end
