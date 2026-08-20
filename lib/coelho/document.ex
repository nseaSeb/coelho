defmodule Coelho.Document do
  @moduledoc """
  Validation, normalisation and plain text extraction of documents.

  A document is a plain map tree with string keys, exactly as it comes out
  of `Jason.decode/1` or out of ProseMirror's `toJSON()`:

      %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "hello", "marks" => [%{"type" => "bold"}]}
            ]
          }
        ]
      }

  No struct wraps it, so what is validated is what is stored, and a jsonb
  round trip is the identity.

  ## Validation is the sanitisation

  `validate/2` is strict on purpose: an unknown node type, an unknown mark,
  an unknown attribute or an attribute failing its validator all reject the
  document. Nothing outside the schema reaches the database, so rendering
  never has to escape its way out of untrusted markup. This is what storing
  the document buys over storing HTML and filtering tags on the way in.

  Validation also normalises: missing optional attributes are filled with
  their schema default, so stored documents are canonical.

  ## Untrusted input

  `validate/2` is the boundary a hostile document hits first, so it is
  written to survive one: node type names are resolved against the schema
  rather than converted to atoms, nesting deeper than 100 levels is rejected
  outright, and error paths are accumulated in reverse so that validating a
  deep document stays linear in its size.
  """

  @max_depth 100

  alias Coelho.Document.Error
  alias Coelho.Schema
  alias Coelho.Schema.{Attr, ContentExpression, NodeSpec}

  @node_keys ~w(type attrs content marks text)
  @mark_keys ~w(type attrs)

  # The VM keeps binaries over 64 bytes off the process heap and hands out
  # sub-binaries that keep their *whole parent* alive. A decoded document is
  # made of exactly those: every string in it points into the payload it was
  # parsed from. Measured, a 500 byte text node out of a 401 KB payload
  # reports `:binary.referenced_byte_size/1` of 401 KB.
  #
  # A validated document is the value that outlives its source — it sits in
  # socket assigns, in a changeset, in the row — so validation copies the
  # strings it keeps and lets the payload go.
  @refc_threshold 64

  @doc """
  Validates and normalises a document against a schema.

  Returns the normalised document, or every error found. Paths in the
  errors read from the root, as in `content[0].attrs.href`.
  """
  @spec validate(term(), Schema.t()) :: {:ok, map()} | {:error, [Error.t()]}
  def validate(document, %Schema{} = schema) do
    {normalised, type, errors} = validate_node(document, schema, [], :all, 0)

    root_errors =
      if type != nil and type != schema.top_node do
        [error([], "document must be a #{schema.top_node}, got #{type}")]
      else
        []
      end

    case root_errors ++ errors do
      [] -> {:ok, normalised}
      errors -> {:error, errors}
    end
  end

  @doc """
  Extracts the plain text of a document, for full text search.
  """
  @spec to_text(map(), Schema.t()) :: String.t()
  def to_text(document, %Schema{} = schema) do
    document
    |> text_iodata(schema)
    |> IO.iodata_to_binary()
    |> strip_block_terminator()
  end

  # -- Validation -----------------------------------------------------------

  # Paths are accumulated reversed and turned around once, when an error is
  # built. Appending to the path at every level instead makes validation
  # quadratic in document depth, which is a denial of service on input that
  # is untrusted by definition.
  #
  # Returns `{normalised_node, type, errors}`. `type` is nil when the node
  # could not be resolved, which tells the caller to skip the content
  # expression check rather than pile a second, meaningless error on top.
  defp validate_node(_node, _schema, rpath, _allowed_marks, depth) when depth > @max_depth do
    {nil, nil, [error(rpath, "document is nested more than #{@max_depth} levels deep")]}
  end

  defp validate_node(node, schema, rpath, allowed_marks, depth) when is_map(node) do
    with {:ok, type} <- fetch_type(node, schema, rpath),
         %NodeSpec{} = spec <- Schema.node_spec(schema, type) do
      unknown_errors = unknown_key_errors(node, @node_keys, rpath)
      {attrs, attr_errors} = validate_attrs(node, spec.attrs, rpath)
      {text, text_errors} = validate_text(node, spec, rpath)
      {marks, mark_errors} = validate_marks(node, spec, allowed_marks, schema, rpath)
      {content, content_errors} = validate_content(node, spec, schema, rpath, depth)

      normalised =
        %{"type" => Atom.to_string(type)}
        |> put_unless_empty("attrs", attrs)
        |> put_unless_empty("marks", marks)
        |> put_unless_empty("content", content)
        |> put_unless_nil("text", text)

      errors = unknown_errors ++ attr_errors ++ text_errors ++ mark_errors ++ content_errors
      {normalised, type, errors}
    else
      {:error, error} -> {nil, nil, [error]}
    end
  end

  defp validate_node(_node, _schema, rpath, _allowed_marks, _depth) do
    {nil, nil, [error(rpath, "expected an object")]}
  end

  defp fetch_type(node, schema, rpath) do
    case Map.fetch(node, "type") do
      {:ok, type} ->
        case Schema.resolve_node_name(schema, type) do
          {:ok, name} -> {:ok, name}
          :error -> {:error, error(rpath, "unknown node type #{inspect(type)}")}
        end

      :error ->
        {:error, error(rpath, ~s(missing "type"))}
    end
  end

  defp unknown_key_errors(node, allowed, rpath) do
    for {key, _value} <- node, key not in allowed do
      error(rpath, "unknown key #{inspect(key)}")
    end
  end

  defp validate_attrs(node, specs, rpath) do
    given = Map.get(node, "attrs", %{})

    if is_map(given) do
      known = MapSet.new(specs, fn {name, _} -> Atom.to_string(name) end)

      unknown =
        for {key, _} <- given,
            not MapSet.member?(known, key),
            do: error(["attrs" | rpath], "unknown attribute #{inspect(key)}")

      {attrs, errors} =
        Enum.reduce(specs, {%{}, []}, fn {name, %Attr{} = spec}, {attrs, errors} ->
          key = Atom.to_string(name)
          attr_rpath = [key, "attrs" | rpath]

          case Map.fetch(given, key) do
            {:ok, value} ->
              case Attr.validate(spec.validate, value) do
                :ok -> {Map.put(attrs, key, compact(value)), errors}
                {:error, message} -> {attrs, [error(attr_rpath, message) | errors]}
              end

            :error when spec.required ->
              {attrs, [error(attr_rpath, "is required") | errors]}

            :error ->
              {Map.put(attrs, key, spec.default), errors}
          end
        end)

      {attrs, unknown ++ Enum.reverse(errors)}
    else
      {%{}, [error(["attrs" | rpath], "expected an object")]}
    end
  end

  # Which marks may appear is a property of the *parent*: ProseMirror's
  # `marks` spec reads "the marks allowed inside this node". Checking the
  # mark against the node that carries it would let a bold text node sit
  # inside a code block that forbids every mark.
  defp validate_marks(node, spec, allowed_marks, schema, rpath) do
    case Map.get(node, "marks", []) do
      [] ->
        {[], []}

      marks when is_list(marks) ->
        if spec.inline do
          marks
          |> Enum.with_index()
          |> Enum.reduce({[], []}, fn {mark, index}, {kept, errors} ->
            mark_rpath = [index, "marks" | rpath]

            case validate_mark(mark, allowed_marks, schema, mark_rpath) do
              {:ok, mark} -> {[mark | kept], errors}
              {:error, mark_errors} -> {kept, [mark_errors | errors]}
            end
          end)
          |> then(fn {kept, errors} -> {Enum.reverse(kept), concat_reversed(errors)} end)
        else
          {[], [error(["marks" | rpath], "marks are only allowed on inline nodes")]}
        end

      _other ->
        {[], [error(["marks" | rpath], "expected a list")]}
    end
  end

  defp validate_mark(mark, allowed_marks, schema, rpath) when is_map(mark) do
    with {:ok, type} <- Map.fetch(mark, "type"),
         {:ok, name} <- Schema.resolve_mark_name(schema, type),
         true <- mark_allowed?(allowed_marks, name) do
      spec = Schema.mark_spec(schema, name)
      {attrs, errors} = validate_attrs(mark, spec.attrs, rpath)

      case unknown_key_errors(mark, @mark_keys, rpath) ++ errors do
        [] -> {:ok, put_unless_empty(%{"type" => Atom.to_string(name)}, "attrs", attrs)}
        errors -> {:error, errors}
      end
    else
      :error ->
        {:error, [error(rpath, ~s(missing or unknown "type"))]}

      false ->
        {:error, [error(rpath, "mark #{inspect(mark["type"])} is not allowed on this node")]}
    end
  end

  defp validate_mark(_mark, _allowed_marks, _schema, rpath),
    do: {:error, [error(rpath, "expected an object")]}

  defp mark_allowed?(:all, _name), do: true
  defp mark_allowed?(allowed, name) when is_list(allowed), do: name in allowed

  defp validate_text(node, %NodeSpec{text: true}, rpath) do
    case Map.fetch(node, "text") do
      {:ok, text} when is_binary(text) and text != "" -> {compact(text), []}
      {:ok, ""} -> {nil, [error(["text" | rpath], "must not be empty")]}
      {:ok, _} -> {nil, [error(["text" | rpath], "must be a string")]}
      :error -> {nil, [error(["text" | rpath], "is required")]}
    end
  end

  defp validate_text(node, _spec, rpath) do
    if Map.has_key?(node, "text") do
      {nil, [error(["text" | rpath], "only a text node may carry text")]}
    else
      {nil, []}
    end
  end

  defp validate_content(node, spec, schema, rpath, depth) do
    case Map.get(node, "content", []) do
      children when is_list(children) ->
        {normalised, types, errors} =
          validate_children(children, schema, rpath, spec.marks, depth + 1)

        {normalised, errors ++ content_errors(spec, children, types, schema, rpath)}

      _other ->
        {[], [error(["content" | rpath], "expected a list")]}
    end
  end

  defp validate_children(children, schema, rpath, allowed_marks, depth) do
    children
    |> Enum.with_index()
    |> Enum.reduce({[], [], []}, fn {child, index}, {nodes, types, errors} ->
      child_rpath = [index, "content" | rpath]
      {node, type, child_errors} = validate_node(child, schema, child_rpath, allowed_marks, depth)
      {[node | nodes], [type | types], [child_errors | errors]}
    end)
    |> then(fn {nodes, types, errors} ->
      {nodes |> Enum.reverse() |> Enum.reject(&is_nil/1), Enum.reverse(types),
       concat_reversed(errors)}
    end)
  end

  defp content_errors(%NodeSpec{content: nil}, [], _types, _schema, _rpath), do: []

  defp content_errors(%NodeSpec{content: nil, name: name}, _children, _types, _schema, rpath),
    do: [error(["content" | rpath], "#{name} cannot hold content")]

  defp content_errors(%NodeSpec{} = spec, _children, types, schema, rpath) do
    cond do
      Enum.any?(types, &is_nil/1) ->
        # A child failed to resolve; its own error already explains why, and
        # the content expression cannot say anything useful about a hole.
        []

      ContentExpression.matches?(spec.content, types, &Schema.instance_of?(schema, &1, &2)) ->
        []

      true ->
        [
          error(
            ["content" | rpath],
            "does not match the content expression #{inspect(spec.content_source)}, " <>
              "got #{inspect(Enum.map(types, &Atom.to_string/1))}"
          )
        ]
    end
  end

  # Appending each child's errors to the growing accumulator would make
  # validation quadratic in the number of failing siblings, which is the same
  # denial of service the reversed paths above avoid for depth.
  defp concat_reversed(lists), do: lists |> Enum.reverse() |> Enum.concat()

  defp put_unless_empty(map, _key, value) when value == %{} or value == [], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp error(rpath, message), do: %Error{path: Enum.reverse(rpath), message: message}

  # `:binary.referenced_byte_size/1` exceeds the value's own size only for a
  # sub-binary, so this copies exactly the strings that would pin something
  # larger, and leaves every other term alone.
  defp compact(value) when is_binary(value) and byte_size(value) > @refc_threshold do
    if :binary.referenced_byte_size(value) > byte_size(value) do
      :binary.copy(value)
    else
      value
    end
  end

  defp compact(value), do: value

  # -- Plain text -----------------------------------------------------------

  defp text_iodata(node, schema) when is_map(node) do
    with {:ok, type} <- Map.fetch(node, "type"),
         {:ok, name} <- Schema.resolve_node_name(schema, type),
         %NodeSpec{} = spec <- Schema.node_spec(schema, name) do
      node_text(spec, node, schema)
    else
      _ -> []
    end
  end

  defp text_iodata(_node, _schema), do: []

  defp node_text(%NodeSpec{to_text: to_text}, node, _schema) when to_text != nil do
    if is_function(to_text, 1), do: to_text.(node), else: to_text
  end

  defp node_text(%NodeSpec{text: true}, node, _schema) do
    case Map.get(node, "text") do
      text when is_binary(text) -> text
      _ -> []
    end
  end

  defp node_text(%NodeSpec{inline: true}, node, schema), do: children_text(node, schema)

  # A block terminates each run of inline children with a break, and leaves
  # block children alone: those already terminated themselves. Deciding once
  # for the whole node instead would drop the separator on content that mixes
  # the two, such as "inline* block*".
  defp node_text(%NodeSpec{}, node, schema) do
    case Map.get(node, "content", []) do
      [] ->
        "\n"

      children ->
        children
        |> Enum.chunk_by(&block?(&1, schema))
        |> Enum.map(&chunk_text(&1, schema))
    end
  end

  defp chunk_text([first | _] = chunk, schema) do
    text = Enum.map(chunk, &text_iodata(&1, schema))

    if block?(first, schema), do: text, else: [text, "\n"]
  end

  defp children_text(node, schema) do
    node |> Map.get("content", []) |> Enum.map(&text_iodata(&1, schema))
  end

  defp block?(child, schema) when is_map(child) do
    with type when is_binary(type) <- Map.get(child, "type"),
         {:ok, name} <- Schema.resolve_node_name(schema, type),
         %NodeSpec{inline: false} <- Schema.node_spec(schema, name) do
      true
    else
      _ -> false
    end
  end

  defp block?(_child, _schema), do: false

  # Only the terminator the last block added comes off; blank paragraphs
  # before it are content, and dropping them would silently reflow the text.
  defp strip_block_terminator(""), do: ""

  defp strip_block_terminator(text) do
    case text do
      <<prefix::binary-size(byte_size(text) - 1), "\n">> -> prefix
      text -> text
    end
  end
end
