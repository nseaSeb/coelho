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

  Callers can override any of them per call through the `:nodes` and
  `:marks` options, which is how a Phoenix application injects its own
  markup — mentions, embeds, syntax highlighted code — without changing what
  is stored.

  The `:context` option carries whatever the render functions need from the
  application and cannot know on their own. Attachments use it to turn a
  stored key into a URL at render time, which is what lets signed and
  expiring URLs work at all — see `Coelho.Attachments`.

  Only validated documents should be rendered. Rendering does not re-check
  the document against the schema; it trusts `Coelho.Document.validate/2`
  to have run, and raises on anything it does not recognise.
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
  Escapes text for inclusion in HTML, attribute values included.
  """
  @spec escape(String.t()) :: iodata()
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
  are not re-validated on the way out — `Coelho.Ecto.Type.load/3` deliberately
  trusts what is in the column. A row written before the schema tightened, by
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
  @spec tag(String.t(), [{String.t(), term()}], iodata()) :: iodata()
  def tag(name, attrs, inner) do
    ["<", name, attributes(attrs), ">", inner, "</", name, ">"]
  end

  @doc """
  Builds a self-closing element.
  """
  @spec void_tag(String.t(), [{String.t(), term()}]) :: iodata()
  def void_tag(name, attrs), do: ["<", name, attributes(attrs), ">"]

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
      nil -> inner
      fun when is_function(fun, 2) -> fun.(node, inner)
      fun when is_function(fun, 3) -> fun.(node, inner, context)
      {tag, attrs} when spec.void -> void_tag(tag, resolve_attrs(attrs, node, context))
      {tag, attrs} -> tag(tag, resolve_attrs(attrs, node, context), inner)
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
      nil -> inner
      fun when is_function(fun, 2) -> fun.(mark, inner)
      fun when is_function(fun, 3) -> fun.(mark, inner, state.context)
      {tag, attrs} -> tag(tag, resolve_attrs(attrs, mark, state.context), inner)
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
