defmodule Coelho.Schema do
  @moduledoc """
  A rich text schema: the set of node and mark types a document may use.

  The schema is the single source of truth of a Coelho document. It is
  declared once in Elixir, used server side to validate and render
  documents, and exported with `to_json/1` to build the matching
  ProseMirror schema in the browser. A document the server would reject is
  therefore a document the client could not have produced.

  ## Declaring a schema

      Coelho.Schema.new(
        top_node: :doc,
        nodes: [
          doc: [content: "block+"],
          paragraph: [content: "inline*", group: "block", render: {"p", []}],
          text: [group: "inline", inline: true, text: true]
        ],
        marks: [
          bold: [render: {"strong", []}]
        ]
      )

  Node and mark declaration order is preserved: ProseMirror resolves default
  types by position, so the first node of a group is its default.

  A `text` node is injected automatically when the declaration omits it.
  """

  alias Coelho.Schema.{Attr, ContentExpression, MarkSpec, NodeSpec}

  @type t :: %__MODULE__{
          top_node: atom(),
          nodes: %{optional(atom()) => NodeSpec.t()},
          marks: %{optional(atom()) => MarkSpec.t()},
          node_order: [atom()],
          mark_order: [atom()],
          groups: %{optional(atom()) => MapSet.t(atom())},
          node_names: %{optional(String.t()) => atom()},
          mark_names: %{optional(String.t()) => atom()}
        }

  defstruct top_node: :doc,
            nodes: %{},
            marks: %{},
            node_order: [],
            mark_order: [],
            groups: %{},
            node_names: %{},
            mark_names: %{}

  @doc """
  Builds a schema from a declaration.

  Raises `ArgumentError` when the declaration is inconsistent: an unparsable
  content expression, a name no node or group answers to, an unknown mark in
  a node's `:marks` list, or a missing top node. A schema is developer
  authored, so an invalid one is a bug rather than a runtime condition.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    top_node = Keyword.get(opts, :top_node, :doc)
    node_decls = opts |> Keyword.get(:nodes, []) |> ensure_text_node()
    mark_decls = Keyword.get(opts, :marks, [])

    marks = Map.new(mark_decls, fn {name, decl} -> {name, build_mark(name, decl)} end)
    nodes = Map.new(node_decls, fn {name, decl} -> {name, build_node(name, decl)} end)

    schema = %__MODULE__{
      top_node: top_node,
      nodes: nodes,
      marks: marks,
      node_order: Enum.map(node_decls, &elem(&1, 0)),
      mark_order: Enum.map(mark_decls, &elem(&1, 0)),
      groups: build_groups(nodes),
      node_names: Map.new(nodes, fn {name, _} -> {Atom.to_string(name), name} end),
      mark_names: Map.new(marks, fn {name, _} -> {Atom.to_string(name), name} end)
    }

    validate_schema!(schema)
    schema
  end

  @doc """
  The schema Coelho ships with: paragraphs, headings, lists, quotes, code
  blocks, images, and the usual inline marks.
  """
  @spec default() :: t()
  def default, do: Coelho.Schema.Default.schema()

  @doc """
  Looks up a node spec by name, returning `nil` when unknown.
  """
  @spec node_spec(t(), atom()) :: NodeSpec.t() | nil
  def node_spec(%__MODULE__{} = schema, name), do: Map.get(schema.nodes, name)

  @doc """
  Looks up a mark spec by name, returning `nil` when unknown.
  """
  @spec mark_spec(t(), atom()) :: MarkSpec.t() | nil
  def mark_spec(%__MODULE__{} = schema, name), do: Map.get(schema.marks, name)

  @doc """
  Resolves a node type name coming from untrusted input.

  Never converts to an atom blindly: only names the schema already knows are
  resolved, so a hostile document cannot grow the atom table.
  """
  @spec resolve_node_name(t(), term()) :: {:ok, atom()} | :error
  def resolve_node_name(%__MODULE__{} = schema, name) when is_binary(name) do
    case Map.fetch(schema.node_names, name) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  def resolve_node_name(_schema, _name), do: :error

  @doc """
  Resolves a mark type name coming from untrusted input.
  """
  @spec resolve_mark_name(t(), term()) :: {:ok, atom()} | :error
  def resolve_mark_name(%__MODULE__{} = schema, name) when is_binary(name) do
    case Map.fetch(schema.mark_names, name) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  def resolve_mark_name(_schema, _name), do: :error

  @doc """
  Whether a node type answers to a name used in a content expression, either
  because it is that node, or because it belongs to that group.
  """
  @spec instance_of?(t(), atom(), atom()) :: boolean()
  def instance_of?(%__MODULE__{} = schema, name, node_type) do
    name == node_type or
      case Map.fetch(schema.groups, name) do
        {:ok, members} -> MapSet.member?(members, node_type)
        :error -> false
      end
  end

  @doc """
  Exports the schema in the shape the browser side consumes to build the
  matching ProseMirror schema.

  Nodes and marks are emitted as ordered pairs rather than objects: node
  order carries meaning in ProseMirror and map key order does not survive a
  round trip through Elixir.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = schema) do
    %{
      "topNode" => Atom.to_string(schema.top_node),
      "nodes" =>
        Enum.map(schema.node_order, &[Atom.to_string(&1), node_to_json(schema.nodes[&1])]),
      "marks" =>
        Enum.map(schema.mark_order, &[Atom.to_string(&1), mark_to_json(schema.marks[&1])])
    }
  end

  defp node_to_json(%NodeSpec{} = spec) do
    %{}
    |> put_unless_nil("content", spec.content_source)
    |> put_unless_nil("group", groups_to_json(spec.group))
    |> put_unless_nil("marks", marks_to_json(spec.marks))
    |> put_unless_nil("attrs", attrs_to_json(spec.attrs))
    |> put_when_true("inline", spec.inline)
    |> put_when_true("atom", spec.void)
  end

  defp mark_to_json(%MarkSpec{} = spec) do
    put_unless_nil(%{}, "attrs", attrs_to_json(spec.attrs))
  end

  defp groups_to_json([]), do: nil
  defp groups_to_json(groups), do: Enum.map_join(groups, " ", &Atom.to_string/1)

  # ProseMirror reads an absent `marks` as "every mark allowed" and an empty
  # string as "none", which is exactly the distinction `:all` versus `[]`
  # carries here.
  defp marks_to_json(:all), do: nil
  defp marks_to_json([]), do: ""
  defp marks_to_json(marks), do: Enum.map_join(marks, " ", &Atom.to_string/1)

  defp attrs_to_json(attrs) when map_size(attrs) == 0, do: nil

  defp attrs_to_json(attrs) do
    Map.new(attrs, fn {name, %Attr{} = attr} ->
      json = if attr.required, do: %{}, else: %{"default" => attr.default}
      {Atom.to_string(name), json}
    end)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_when_true(map, _key, false), do: map
  defp put_when_true(map, key, true), do: Map.put(map, key, true)

  # -- Construction ---------------------------------------------------------

  defp ensure_text_node(nodes) do
    if Keyword.has_key?(nodes, :text) do
      nodes
    else
      nodes ++ [text: [group: "inline", inline: true, text: true]]
    end
  end

  defp build_node(name, decl) do
    content_source = Keyword.get(decl, :content)

    %NodeSpec{
      name: name,
      content_source: content_source,
      content: parse_content!(name, content_source),
      group: normalize_groups(Keyword.get(decl, :group, [])),
      marks: normalize_marks(Keyword.get(decl, :marks, :all)),
      attrs: build_attrs(Keyword.get(decl, :attrs, [])),
      inline: Keyword.get(decl, :inline, false),
      text: Keyword.get(decl, :text, false),
      void: Keyword.get(decl, :void, false),
      render: Keyword.get(decl, :render),
      to_text: Keyword.get(decl, :to_text)
    }
  end

  defp build_mark(name, decl) do
    %MarkSpec{
      name: name,
      attrs: build_attrs(Keyword.get(decl, :attrs, [])),
      render: Keyword.get(decl, :render)
    }
  end

  defp build_attrs(attrs) do
    Map.new(attrs, fn
      {name, %Attr{} = attr} -> {name, attr}
      {name, opts} when is_list(opts) -> {name, Attr.new(opts)}
    end)
  end

  defp parse_content!(_name, nil), do: nil

  defp parse_content!(name, source) do
    case ContentExpression.parse(source) do
      {:ok, ast} ->
        ast

      {:error, message} ->
        raise ArgumentError,
              "invalid content expression #{inspect(source)} on node #{inspect(name)}: #{message}"
    end
  end

  defp normalize_groups(groups) when is_binary(groups),
    do: groups |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.to_atom/1)

  defp normalize_groups(groups) when is_atom(groups), do: [groups]
  defp normalize_groups(groups) when is_list(groups), do: groups

  defp normalize_marks(:all), do: :all
  defp normalize_marks(:none), do: []

  defp normalize_marks(marks) when is_binary(marks),
    do: marks |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.to_atom/1)

  defp normalize_marks(marks) when is_list(marks), do: marks

  defp build_groups(nodes) do
    Enum.reduce(nodes, %{}, fn {name, spec}, acc ->
      Enum.reduce(spec.group, acc, fn group, acc ->
        Map.update(acc, group, MapSet.new([name]), &MapSet.put(&1, name))
      end)
    end)
  end

  # -- Consistency ----------------------------------------------------------

  defp validate_schema!(schema) do
    # `nodes` is a map, so a name declared twice silently keeps the last body
    # while `node_order` keeps both entries — and `to_json/1` would then emit
    # the same name twice, building an invalid ProseMirror schema.
    reject_duplicates!(schema.node_order, "node")
    reject_duplicates!(schema.mark_order, "mark")

    unless Map.has_key?(schema.nodes, schema.top_node) do
      raise ArgumentError, "top node #{inspect(schema.top_node)} is not declared"
    end

    known = MapSet.union(MapSet.new(Map.keys(schema.nodes)), MapSet.new(Map.keys(schema.groups)))

    for {name, spec} <- schema.nodes do
      if spec.content do
        for referenced <- ContentExpression.names(spec.content),
            not MapSet.member?(known, referenced) do
          raise ArgumentError,
                "node #{inspect(name)} references #{inspect(referenced)} in its content " <>
                  "expression, but no node or group answers to that name"
        end
      end

      if is_list(spec.marks) do
        for mark <- spec.marks, not Map.has_key?(schema.marks, mark) do
          raise ArgumentError, "node #{inspect(name)} allows unknown mark #{inspect(mark)}"
        end
      end
    end

    :ok
  end

  defp reject_duplicates!(names, kind) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      duplicates -> raise ArgumentError, "#{kind} #{inspect(hd(duplicates))} is declared twice"
    end
  end
end
