defmodule Coelho do
  @moduledoc """
  Structured rich text for Elixir.

  Coelho stores a rich text document as a validated tree — the same shape
  ProseMirror produces — rather than as a blob of HTML. A schema, written
  once in Elixir, says which nodes and marks exist; validating a document
  against it *is* the sanitisation step, and rendering it is a pure function
  the application can override node by node.

  This module is the convenience surface over the three that do the work:

    * `Coelho.Schema` — declaring the schema and exporting it to the browser
    * `Coelho.Document` — validating, normalising, extracting plain text
    * `Coelho.Render` — turning a validated document into HTML

  Every function here defaults to `Coelho.Schema.default/0`; applications
  with their own schema call the underlying modules directly.

      iex> document = %{
      ...>   "type" => "doc",
      ...>   "content" => [
      ...>     %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hello"}]}
      ...>   ]
      ...> }
      iex> {:ok, document} = Coelho.validate(document)
      iex> Coelho.to_html(document)
      "<p>hello</p>"

  """

  alias Coelho.{Document, Render, Schema}

  @doc """
  Validates and normalises a document against a schema.
  """
  @spec validate(term(), Schema.t()) :: {:ok, map()} | {:error, [Document.Error.t()]}
  def validate(document, schema \\ Schema.default()), do: Document.validate(document, schema)

  @doc """
  Renders a validated document to HTML.

  The schema may be left out, in which case the render options can be passed
  straight as the second argument.
  """
  @spec to_html(map()) :: String.t()
  def to_html(document), do: Render.to_html(document, Schema.default(), [])

  @spec to_html(map(), Schema.t() | Render.opts()) :: String.t()
  def to_html(document, opts) when is_list(opts),
    do: Render.to_html(document, Schema.default(), opts)

  def to_html(document, %Schema{} = schema), do: Render.to_html(document, schema, [])

  @spec to_html(map(), Schema.t(), Render.opts()) :: String.t()
  def to_html(document, %Schema{} = schema, opts), do: Render.to_html(document, schema, opts)

  @doc """
  Extracts the plain text of a document, for full text search.
  """
  @spec to_text(map(), Schema.t()) :: String.t()
  def to_text(document, schema \\ Schema.default()), do: Document.to_text(document, schema)

  @doc """
  The empty document of a schema.

  The child is derived from the top node's content expression rather than
  assumed to be a paragraph, so a schema that calls its block node something
  else still gets a document its own `validate/2` accepts.
  """
  @spec empty(Schema.t()) :: map()
  def empty(schema \\ Schema.default()) do
    top = Schema.node_spec(schema, schema.top_node)
    document = %{"type" => Atom.to_string(schema.top_node)}

    case empty_child(schema, top) do
      nil -> document
      child -> Map.put(document, "content", [%{"type" => Atom.to_string(child)}])
    end
  end

  defp empty_child(_schema, %Schema.NodeSpec{content: nil}), do: nil

  defp empty_child(schema, %Schema.NodeSpec{content: content}) do
    matches? = fn children ->
      Schema.ContentExpression.matches?(content, children, &Schema.instance_of?(schema, &1, &2))
    end

    if matches?.([]) do
      nil
    else
      Enum.find(schema.node_order, fn name ->
        spec = Schema.node_spec(schema, name)
        usable_empty?(schema, spec) and matches?.([name])
      end)
    end
  end

  # A candidate is only usable if it is itself valid while empty: picking a
  # list item for a "list_item+" top node, or a mention that requires a
  # user id, would build a document that fails validation on the very next
  # line — and seed a new record form that is invalid before the user types.
  defp usable_empty?(schema, %Schema.NodeSpec{} = spec) do
    childless?(schema, spec) and Enum.all?(spec.attrs, fn {_name, attr} -> not attr.required end)
  end

  defp childless?(_schema, %Schema.NodeSpec{content: nil}), do: true

  defp childless?(schema, %Schema.NodeSpec{content: content}) do
    Schema.ContentExpression.matches?(content, [], &Schema.instance_of?(schema, &1, &2))
  end
end
