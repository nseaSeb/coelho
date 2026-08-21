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
  A byte-for-byte stable serialisation of a validated document.
  """
  @spec canonical(term()) :: binary()
  defdelegate canonical(document), to: Document

  @doc """
  Validates and normalises a document against a schema.
  """
  @spec validate(term(), Schema.t()) :: {:ok, map()} | {:error, [Document.Error.t()]}
  def validate(document, schema \\ Schema.default()), do: Document.validate(document, schema)

  @doc """
  Turns any term into a document the schema accepts, without failing.

  The counterpart of `validate/2` for the way out: see
  `Coelho.Document.sanitize/2` for what it removes and why a stored document
  needs it at all.
  """
  @spec sanitize(term(), Schema.t()) :: map()
  def sanitize(document, schema \\ Schema.default()), do: Document.sanitize(document, schema)

  @doc """
  The number of characters a writer typed, counted the way the editor counts.
  """
  @spec text_length(term()) :: non_neg_integer()
  def text_length(document), do: Document.text_length(document)

  @doc """
  The hex digest of a validated document, or `nil` when it holds nothing.
  """
  @spec hash(term(), :sha256 | :sha512 | :sha384 | :sha224 | :sha) :: String.t() | nil
  def hash(document, algorithm \\ :sha256), do: Document.hash(document, algorithm)

  @doc """
  Moves a document from one schema version to the next.

  A schema that declares a `:version` stamps it on every document it
  validates, and refuses a document stamped with another — which is the
  whole point: when a node is renamed or an attribute retired, there is
  otherwise no way to tell a document written under the old vocabulary from
  one that is simply wrong.

      Coelho.migrate(document, from: 1, to: 2, with: &MyApp.RichText.v1_to_v2/1)

  `:with` takes the document and returns the rewritten one. Crossing more
  than one version at a time takes a map of the step to run *into* each
  version:

      Coelho.migrate(document, from: 1, to: 3, with: %{2 => &v1_to_v2/1, 3 => &v2_to_v3/1})

  The result is stamped with `:to` and is **not** validated: run it through
  `validate/2` with the new schema, which is where a migration that missed
  something says so.
  """
  @spec migrate(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def migrate(document, opts) when is_map(document) and is_list(opts) do
    from = version!(opts, :from)
    to = version!(opts, :to)
    steps = Keyword.fetch!(opts, :with)

    with :ok <- check_direction(from, to),
         :ok <- check_migration_version(document, from),
         {:ok, migrated} <- run_migration(document, from, to, steps) do
      {:ok, Map.put(migrated, "schema_version", to)}
    end
  end

  # A version that is not a positive integer is a call written wrong, not a
  # document that failed: raising says so where it happened, instead of an
  # ArithmeticError from inside the step loop.
  defp version!(opts, key) do
    case Keyword.fetch!(opts, key) do
      version when is_integer(version) and version > 0 ->
        version

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer, got #{inspect(other)}"
    end
  end

  defp check_direction(from, to) when to >= from, do: :ok

  defp check_direction(from, to),
    do: {:error, "cannot migrate backwards, from #{from} to #{to}"}

  defp check_migration_version(document, from) do
    case Map.get(document, "schema_version", from) do
      ^from -> :ok
      other -> {:error, "document is at schema version #{inspect(other)}, not #{inspect(from)}"}
    end
  end

  defp run_migration(document, from, to, _steps) when from == to, do: {:ok, document}

  defp run_migration(document, from, to, fun) when is_function(fun, 1) do
    if to == from + 1 do
      {:ok, fun.(document)}
    else
      {:error,
       "migrating from #{from} to #{to} crosses more than one version; " <>
         "give :with a map of the step into each version"}
    end
  end

  defp run_migration(document, from, to, steps) when is_map(steps) do
    Enum.reduce_while((from + 1)..to, {:ok, document}, fn version, {:ok, document} ->
      case Map.fetch(steps, version) do
        {:ok, fun} -> {:cont, {:ok, fun.(document)}}
        :error -> {:halt, {:error, "no migration step into schema version #{version}"}}
      end
    end)
  end

  defp run_migration(_document, _from, _to, steps) do
    raise ArgumentError,
          ":with must be a function of the document, or a map of the step into each " <>
            "version, got #{inspect(steps)}"
  end

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
  Renders a validated document as `{:safe, iodata}`, for a template.

  The form that needs no `raw/1` — see `Coelho.Render.to_safe_html/3`.
  """
  @spec to_safe_html(map()) :: {:safe, iodata()}
  def to_safe_html(document), do: Render.to_safe_html(document, Schema.default(), [])

  @spec to_safe_html(map(), Schema.t() | Render.opts()) :: {:safe, iodata()}
  def to_safe_html(document, opts) when is_list(opts),
    do: Render.to_safe_html(document, Schema.default(), opts)

  def to_safe_html(document, %Schema{} = schema), do: Render.to_safe_html(document, schema, [])

  @spec to_safe_html(map(), Schema.t(), Render.opts()) :: {:safe, iodata()}
  def to_safe_html(document, %Schema{} = schema, opts),
    do: Render.to_safe_html(document, schema, opts)

  @doc """
  Whether a document would put anything on the page.

  What to ask before rendering a block at all. See
  `Coelho.Document.blank?/2` — in particular for why
  `text_length(document) == 0` is not the same question.
  """
  @spec blank?(term(), Schema.t()) :: boolean()
  def blank?(document, schema \\ Schema.default()), do: Document.blank?(document, schema)

  @doc """
  Folds a document into any term at all, for a target that is not HTML.

  See `Coelho.Render.reduce/4`.
  """
  @spec reduce(map(), Schema.t(), Render.callbacks(), Render.opts()) :: term()
  def reduce(document, schema \\ Schema.default(), callbacks, opts \\ []),
    do: Render.reduce(document, schema, callbacks, opts)

  @doc """
  Converts existing HTML into a validated document, and says what it left
  behind.

  The migration path for content already stored as HTML. Requires the
  optional `:floki` dependency; see `Coelho.HTML.from_html/2` for what the
  import does with markup the schema does not know, and for the shape of the
  warnings.
  """
  @spec from_html(String.t(), Schema.t()) ::
          {:ok, map(), [Coelho.HTML.warning()]} | {:error, term()}
  def from_html(html, schema \\ Schema.default()), do: Coelho.HTML.from_html(html, schema)

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
