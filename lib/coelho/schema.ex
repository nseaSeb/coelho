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
  types by position, so the first node of a group is its default. It also
  fixes the order marks are stored in, which is what makes a document
  canonical — see `Coelho.Document.canonical/1`.

  A `text` node is injected automatically when the declaration omits it.

  ## Bounds

  Every schema carries `:limits`, and the defaults apply whether or not the
  application thought about them:

      Coelho.Schema.new(...,
        limits: [max_nodes: 500, max_depth: 6, max_text_length: 20_000]
      )

  A document arrives from the browser in a hidden form field that no
  `maxlength` constrains, so an unbounded schema is an unbounded allocation
  on input that is untrusted by definition. `default_limits/0` is what a
  schema gets when it says nothing; `:infinity` lifts a bound deliberately.

  ## Narrowing

  Several rich text fields in one application usually want different
  vocabularies. `restrict/2` subtracts from a schema rather than restating
  it, so the narrower one cannot drift into accepting more than its parent —
  see `restrict/2`.

  ## Styling the editor as the page is styled

  A node or mark spec may carry a `:class`, which is applied by the server
  renderer *and* exported to the browser, so the writer sees the class the
  public page will carry without an application writing a hook to put it
  there. `:editor_attrs` carries DOM attributes for the editor alone.

  ## Versions

  A schema may declare a `:version`. `Coelho.Document.validate/2` then stamps
  it on every document and refuses one stamped differently, which is what
  makes `Coelho.migrate/2` possible: without it there is no way to tell a
  document written under an older vocabulary from one that is simply wrong.
  """

  alias Coelho.Schema.{Attr, ContentExpression, MarkSpec, NodeSpec}

  @type limits :: %{
          max_nodes: pos_integer() | :infinity,
          max_depth: pos_integer() | :infinity,
          max_text_length: pos_integer() | :infinity
        }

  @type t :: %__MODULE__{
          top_node: atom(),
          fingerprint: non_neg_integer(),
          version: pos_integer() | nil,
          limits: limits(),
          nodes: %{optional(atom()) => NodeSpec.t()},
          marks: %{optional(atom()) => MarkSpec.t()},
          node_order: [atom()],
          mark_order: [atom()],
          groups: %{optional(atom()) => MapSet.t(atom())},
          node_names: %{optional(String.t()) => atom()},
          mark_names: %{optional(String.t()) => atom()}
        }

  # Bounds every document is held to, whether or not the application thought
  # about them. A document arrives in a hidden form field that no `maxlength`
  # constrains, so an unbounded schema is an unbounded allocation on input
  # that is untrusted by definition. The defaults are far above any document
  # a person writes and far below what makes validation expensive.
  @default_limits %{max_nodes: 10_000, max_depth: 100, max_text_length: 1_000_000}

  defstruct top_node: :doc,
            fingerprint: 0,
            version: nil,
            limits: @default_limits,
            nodes: %{},
            marks: %{},
            node_order: [],
            mark_order: [],
            groups: %{},
            node_names: %{},
            mark_names: %{}

  @doc """
  The bounds a schema is given when it does not set its own.
  """
  @spec default_limits() :: limits()
  def default_limits, do: @default_limits

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
      version: build_version(Keyword.get(opts, :version)),
      limits: build_limits(@default_limits, Keyword.get(opts, :limits, [])),
      nodes: nodes,
      marks: marks,
      node_order: Enum.map(node_decls, &elem(&1, 0)),
      mark_order: Enum.map(mark_decls, &elem(&1, 0)),
      groups: build_groups(nodes),
      node_names: Map.new(nodes, fn {name, _} -> {Atom.to_string(name), name} end),
      mark_names: Map.new(marks, fn {name, _} -> {Atom.to_string(name), name} end)
    }

    validate_schema!(schema)
    stamp(schema)
  end

  # Exporting a schema and hashing it costs a few microseconds, which is
  # nothing once and a great deal on a path that runs per keystroke and per
  # render. It is settled here, where a schema is built, because a schema
  # never changes afterwards.
  defp stamp(schema), do: %{schema | fingerprint: schema |> to_json() |> :erlang.phash2()}

  @doc """
  A stable number identifying this schema's exported shape.

  What telemetry metadata carries instead of the schema itself — a schema is
  a few kilobytes of specs and parse rules, and handing every handler a copy
  of it on every keystroke is not a measurement — and what the editor stamps
  on its element so the browser notices the schema moved.

  Two schemas exporting the same JSON have the same fingerprint, whichever
  way they were built.
  """
  @spec fingerprint(t()) :: non_neg_integer()
  def fingerprint(%__MODULE__{fingerprint: fingerprint}), do: fingerprint

  @doc """
  The schema Coelho ships with: paragraphs, headings, lists, quotes, code
  blocks, images, and the usual inline marks.
  """
  @spec default() :: t()
  def default, do: Coelho.Schema.Default.schema()

  # Which fields of a built spec a declaration key is responsible for. Only
  # `:content` answers for two, because the parsed expression and the source
  # it was parsed from have to move together.
  @node_declares [
    content: [:content_source, :content],
    group: [:group],
    marks: [:marks],
    attrs: [:attrs],
    inline: [:inline],
    text: [:text],
    void: [:void],
    class: [:class],
    editor_attrs: [:editor_attrs],
    render: [:render],
    render_inline: [:render_inline],
    to_text: [:to_text],
    parse: [:parse]
  ]

  @mark_declares [
    attrs: [:attrs],
    class: [:class],
    editor_attrs: [:editor_attrs],
    render: [:render],
    parse: [:parse]
  ]

  @doc """
  Adds nodes and marks to an existing schema.

  Most applications want the default schema and one thing of their own — a
  mention, an embed, a callout — and re-declaring the other fifteen nodes to
  get there would guarantee they drift.

      Coelho.Schema.extend(Coelho.Schema.default(),
        nodes: [
          mention: [
            group: "inline",
            inline: true,
            void: true,
            attrs: [user_id: [required: true, validate: :integer], label: [default: nil, validate: {:nullable, :string}]],
            render: &MyApp.RichText.render_mention/2
          ]
        ]
      )

  Additions keep their declaration order, after what was already there.

  ## Redeclaring a name

  Redeclaring an existing name **adjusts** it: what the declaration names is
  taken from the declaration, and what it leaves out is kept from the spec
  already there. Giving the shipped `bold` the class of a theme is a line,
  and it keeps the `parse: ~w(strong b)` it was shipped with:

      Coelho.Schema.extend(schema, marks: [bold: [class: "font-bold"]])

  A whole declaration key is the unit — `attrs: [level: …]` replaces the
  attribute map rather than merging into it, because an attribute that can
  only be added and never taken away is not an override.
  """
  @spec extend(t(), keyword()) :: t()
  def extend(%__MODULE__{} = schema, opts) when is_list(opts) do
    node_decls = Keyword.get(opts, :nodes, [])
    mark_decls = Keyword.get(opts, :marks, [])

    nodes = redeclare(schema.nodes, node_decls, &build_node/2, @node_declares)
    marks = redeclare(schema.marks, mark_decls, &build_mark/2, @mark_declares)

    extended = %{
      schema
      | version: build_version(Keyword.get(opts, :version, schema.version)),
        limits: build_limits(schema.limits, Keyword.get(opts, :limits, [])),
        nodes: nodes,
        marks: marks,
        node_order: append_new(schema.node_order, Keyword.keys(node_decls)),
        mark_order: append_new(schema.mark_order, Keyword.keys(mark_decls)),
        groups: build_groups(nodes),
        node_names: Map.new(nodes, fn {name, _} -> {Atom.to_string(name), name} end),
        mark_names: Map.new(marks, fn {name, _} -> {Atom.to_string(name), name} end)
    }

    validate_schema!(extended)
    stamp(extended)
  end

  defp append_new(existing, added), do: existing ++ Enum.reject(added, &(&1 in existing))

  # A redeclared name keeps what its declaration does not mention. The whole
  # spec is built anyway, so a declaration is checked the same way whether
  # the name is new or not; the built one is then laid over the existing one
  # key by key.
  #
  # Replacing outright is what this used to do, and it lost silently: an
  # application redeclaring `bold` to give it a class got a mark with no
  # `parse:` at all, so a `<strong>` pasted out of a word processor came in
  # as plain text with nothing said about it.
  defp redeclare(existing, decls, build, declares) do
    Enum.reduce(decls, existing, fn {name, decl}, acc ->
      Map.put(acc, name, adjust(Map.get(acc, name), build.(name, decl), decl, declares))
    end)
  end

  defp adjust(nil, built, _decl, _declares), do: built

  defp adjust(existing, built, decl, declares) do
    Enum.reduce(declares, existing, fn {key, fields}, acc ->
      if Keyword.has_key?(decl, key) do
        Enum.reduce(fields, acc, &Map.put(&2, &1, Map.fetch!(built, &1)))
      else
        acc
      end
    end)
  end

  @doc """
  Narrows a schema to a subset of its nodes and marks.

  An application with several rich text fields usually wants one vocabulary
  per field — a portal blurb that is paragraphs and four marks, terms and
  conditions that add headings and lists but only bold and links. Declaring
  each of them with `new/1` means keeping several full schemas consistent by
  hand; this subtracts from one instead.

      Coelho.Schema.restrict(Coelho.Schema.default(),
        nodes: [:paragraph],
        marks: [:bold, :link]
      )

  Only the keys given are narrowed: leaving `:nodes` out keeps every node.
  The top node and the `text` node are always kept, since a schema without
  them could not hold a document at all.

  Limits are narrowed the same way — a value given here applies only if it
  is tighter than the parent's. That is what makes the guarantee hold in
  both directions: **a restricted schema never accepts a document its parent
  would reject.**

  Raises `ArgumentError` when a name is not in the parent — asking to keep
  what is not there is a bug, not a narrowing — and when the narrowing
  leaves a surviving node referring to something that is gone, such as
  keeping `bullet_list` without `list_item`.
  """
  @spec restrict(t(), keyword()) :: t()
  def restrict(%__MODULE__{} = schema, opts) when is_list(opts) do
    kept_marks = kept(opts, :marks, Map.keys(schema.marks), [])
    kept_nodes = kept(opts, :nodes, Map.keys(schema.nodes), [schema.top_node, :text])

    nodes =
      schema.nodes
      |> Map.take(kept_nodes)
      |> Map.new(fn {name, spec} -> {name, restrict_node(spec, kept_marks)} end)

    marks = Map.take(schema.marks, kept_marks)

    restricted = %{
      schema
      | limits: restrict_limits(schema.limits, Keyword.get(opts, :limits, [])),
        nodes: nodes,
        marks: marks,
        node_order: Enum.filter(schema.node_order, &Map.has_key?(nodes, &1)),
        mark_order: Enum.filter(schema.mark_order, &Map.has_key?(marks, &1)),
        groups: build_groups(nodes),
        node_names: Map.new(nodes, fn {name, _} -> {Atom.to_string(name), name} end),
        mark_names: Map.new(marks, fn {name, _} -> {Atom.to_string(name), name} end)
    }

    try do
      validate_schema!(restricted)
    rescue
      error in ArgumentError ->
        reraise ArgumentError,
                [
                  message:
                    error.message <>
                      " — this schema was produced by Coelho.Schema.restrict/2, so the " <>
                      "missing name is one the narrowing removed; keep it, or drop what " <>
                      "refers to it as well"
                ],
                __STACKTRACE__
    end

    stamp(restricted)
  end

  defp kept(opts, key, all, always) do
    case Keyword.get(opts, key) do
      nil ->
        all

      names when not is_list(names) ->
        raise ArgumentError,
              "restrict expects a list of #{key} to keep, got #{inspect(names)}"

      names ->
        for name <- names, name not in all do
          raise ArgumentError,
                "cannot restrict to #{inspect(name)}: the schema declares no such #{singular(key)}"
        end

        Enum.uniq(names ++ Enum.filter(always, &(&1 in all)))
    end
  end

  defp singular(:nodes), do: "node"
  defp singular(:marks), do: "mark"

  # A node's `marks` list names what its children may carry, so a narrowing
  # that removes a mark has to take it out of every list mentioning it, or
  # the schema no longer builds.
  defp restrict_node(%NodeSpec{marks: :all} = spec, _kept), do: spec

  defp restrict_node(%NodeSpec{marks: marks} = spec, kept),
    do: %{spec | marks: Enum.filter(marks, &(&1 in kept))}

  @doc """
  The position of a mark in the schema's declaration order.

  Marks are a set, so the order they are written in carries no meaning —
  which is exactly why a canonical document has to pick one. ProseMirror
  ranks marks by their position in the schema, and `Coelho.Document` sorts
  them the same way, so that the same fragment hashes the same however the
  editor happened to add its marks.
  """
  @spec mark_index(t(), atom()) :: non_neg_integer()
  def mark_index(%__MODULE__{mark_order: order}, name) do
    case Enum.find_index(order, &(&1 == name)) do
      nil -> length(order)
      index -> index
    end
  end

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

  A `:render` and a `:parse` that are *declarations* rather than functions —
  `{"mark", []}`, `parse: ["mark"]` — are exported too, as `renderDOM` and
  `parseDOM`. That is what lets a mark an application added show up in the
  editor without a line of JavaScript: the browser builds its `toDOM` and
  `parseDOM` from them when nothing was passed to `createCoelhoHook`. A
  render function cannot be exported, and neither can a parse rule that
  extracts with one; those still need their browser half declared by hand.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = schema) do
    %{
      "topNode" => Atom.to_string(schema.top_node),
      "limits" => limits_to_json(schema.limits),
      "nodes" =>
        Enum.map(schema.node_order, &[Atom.to_string(&1), node_to_json(schema.nodes[&1])]),
      "marks" =>
        Enum.map(schema.mark_order, &[Atom.to_string(&1), mark_to_json(schema.marks[&1])])
    }
    |> put_unless_nil("version", schema.version)
  end

  defp node_to_json(%NodeSpec{} = spec) do
    %{}
    |> put_unless_nil("content", spec.content_source)
    |> put_unless_nil("group", groups_to_json(spec.group))
    |> put_unless_nil("marks", marks_to_json(spec.marks))
    |> put_unless_nil("attrs", attrs_to_json(spec.attrs))
    |> put_unless_nil("attrRenderAs", attr_render_as_to_json(spec.attrs))
    |> put_unless_nil("editorAttrs", editor_attrs_to_json(spec.class, spec.editor_attrs))
    |> put_unless_nil("renderDOM", render_dom_to_json(spec.render, spec.void))
    |> put_unless_nil("parseDOM", parse_dom_to_json(spec.parse))
    |> put_when_true("inline", spec.inline)
    |> put_when_true("atom", spec.void)
  end

  defp mark_to_json(%MarkSpec{} = spec) do
    %{}
    |> put_unless_nil("attrs", attrs_to_json(spec.attrs))
    |> put_unless_nil("attrRenderAs", attr_render_as_to_json(spec.attrs))
    |> put_unless_nil("editorAttrs", editor_attrs_to_json(spec.class, spec.editor_attrs))
    |> put_unless_nil("renderDOM", render_dom_to_json(spec.render, false))
    |> put_unless_nil("parseDOM", parse_dom_to_json(spec.parse))
  end

  # A ProseMirror DOMOutputSpec, built here from the same declaration the
  # server renders through, so the writer sees the element the reader will.
  # The `0` is ProseMirror's content hole, which a void node has none of.
  #
  # The spec's `:class` is deliberately not merged in: it travels in
  # `editorAttrs` and the browser appends it there, in the order
  # `Coelho.Render` appends it too — the attribute's class, then this one.
  defp render_dom_to_json({tag, attrs}, void) when is_binary(tag) and is_list(attrs) do
    case dom_attrs(attrs) do
      {:ok, exported} -> [tag, exported] ++ if(void, do: [], else: [0])
      :error -> nil
    end
  end

  defp render_dom_to_json(_render, _void), do: nil

  # The values `Coelho.Render.attributes/1` accepts, in the DOM's own
  # spelling: `false` and `nil` write no attribute at all, and a bare one is
  # the empty string — `setAttribute("open", "")` is what draws
  # `<details open>`. Only a value neither half could write is refused, and
  # refusing it here means the browser falls back and says so rather than
  # exporting half an element.
  defp dom_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {name, _value}, _acc when not is_binary(name) ->
        {:halt, :error}

      {_name, value}, acc when value in [nil, false] ->
        {:cont, acc}

      {name, true}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, name, "")}}

      {name, value}, {:ok, acc} when is_binary(value) or is_number(value) or is_atom(value) ->
        {:cont, {:ok, Map.put(acc, name, to_string(value))}}

      _other, _acc ->
        {:halt, :error}
    end)
  end

  # The import rules, in the browser's shape. A rule extracting with a
  # function is left out rather than guessed at — it is the one that knows
  # what an import has to tolerate, and only Elixir can run it.
  defp parse_dom_to_json(rules) do
    case for({tag, attrs} <- rules, is_map(attrs), do: [tag, attrs]) do
      [] -> nil
      exported -> exported
    end
  end

  # `:class` is exported alongside the editor-only attributes rather than on
  # its own key, so the browser has a single thing to merge into `toDOM`.
  # The class is what makes the editor and the public page agree: it is
  # declared once and applied on both sides.
  defp editor_attrs_to_json(nil, attrs) when map_size(attrs) == 0, do: nil
  defp editor_attrs_to_json(nil, attrs), do: attrs
  defp editor_attrs_to_json(class, attrs), do: Map.put(attrs, "class", class)

  # `:infinity` is not JSON, and a bound the browser cannot express is a
  # bound it should not pretend to enforce: it comes out as an absent key.
  defp limits_to_json(limits) do
    for {key, value} <- limits, value != :infinity, into: %{} do
      {key |> Atom.to_string() |> camelize(), value}
    end
  end

  defp camelize("max_nodes"), do: "maxNodes"
  defp camelize("max_depth"), do: "maxDepth"
  defp camelize("max_text_length"), do: "maxTextLength"

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

  # `:render_as` travels beside the attributes rather than inside them: what
  # goes into `attrs` is handed to ProseMirror as an attribute spec, and a
  # key it does not know is a key it is free to give a meaning to later.
  #
  # A `{:style, property}` carries the values it may render, read off the
  # validator it is required to have. The browser is a renderer too, and one
  # that trusted the stored value would show the writer something the page
  # then refuses.
  defp attr_render_as_to_json(attrs) do
    rendered =
      for {name, %Attr{render_as: render_as} = attr} <- attrs,
          render_as != nil,
          into: %{},
          do: {Atom.to_string(name), render_as_to_json(render_as, attr)}

    if rendered == %{}, do: nil, else: rendered
  end

  defp render_as_to_json({:style, property}, attr) do
    %{"style" => property, "values" => Attr.render_values(attr)}
  end

  defp render_as_to_json({:class, classes}, _attr) do
    %{"class" => Map.new(classes, fn {value, class} -> {Attr.class_json_key(value), class} end)}
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
      class: build_class(name, Keyword.get(decl, :class)),
      editor_attrs: build_editor_attrs(name, Keyword.get(decl, :editor_attrs, %{})),
      render: Keyword.get(decl, :render),
      render_inline: Keyword.get(decl, :render_inline),
      to_text: Keyword.get(decl, :to_text),
      parse: normalize_parse(Keyword.get(decl, :parse, []))
    }
  end

  defp build_mark(name, decl) do
    %MarkSpec{
      name: name,
      attrs: build_attrs(Keyword.get(decl, :attrs, [])),
      class: build_class(name, Keyword.get(decl, :class)),
      editor_attrs: build_editor_attrs(name, Keyword.get(decl, :editor_attrs, %{})),
      render: Keyword.get(decl, :render),
      parse: normalize_parse(Keyword.get(decl, :parse, []))
    }
  end

  defp build_class(_name, nil), do: nil
  defp build_class(_name, class) when is_binary(class), do: class

  defp build_class(name, other) do
    raise ArgumentError, "class of #{inspect(name)} must be a string, got #{inspect(other)}"
  end

  defp build_editor_attrs(name, attrs) when is_map(attrs) or is_list(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        {key, value}

      {key, value} when is_atom(key) and is_binary(value) ->
        {Atom.to_string(key), value}

      other ->
        raise ArgumentError,
              "editor_attrs of #{inspect(name)} must map names to strings, got #{inspect(other)}"
    end)
  end

  defp build_editor_attrs(name, other) do
    raise ArgumentError, "editor_attrs of #{inspect(name)} must be a map, got #{inspect(other)}"
  end

  defp build_version(nil), do: nil
  defp build_version(version) when is_integer(version) and version > 0, do: version

  defp build_version(other) do
    raise ArgumentError, "schema version must be a positive integer, got #{inspect(other)}"
  end

  @limit_keys [:max_nodes, :max_depth, :max_text_length]

  # Public for `Coelho.Document.sanitize/3`, which takes the same keyword
  # list and has to check it the same way, and for nobody else: a schema is
  # declared with `new/1`, `extend/2` and `restrict/2`.
  @doc false
  @spec build_limits(limits(), keyword()) :: limits()
  def build_limits(base, given) do
    Enum.reduce(given, base, fn {key, value}, acc ->
      unless key in @limit_keys do
        raise ArgumentError,
              "unknown limit #{inspect(key)}, expected one of #{inspect(@limit_keys)}"
      end

      Map.put(acc, key, valid_limit!(key, value))
    end)
  end

  defp valid_limit!(_key, :infinity), do: :infinity
  defp valid_limit!(_key, value) when is_integer(value) and value > 0, do: value

  defp valid_limit!(key, other) do
    raise ArgumentError,
          "limit #{inspect(key)} must be a positive integer or :infinity, got #{inspect(other)}"
  end

  # A narrowing may only tighten. Taking the minimum rather than rejecting a
  # looser value keeps `restrict/2` usable with a limits list written once
  # and applied to several parents.
  defp restrict_limits(parent, given) do
    parent
    |> build_limits(given)
    |> Map.new(fn {key, value} -> {key, min_limit(value, Map.fetch!(parent, key))} end)
  end

  defp min_limit(:infinity, other), do: other
  defp min_limit(value, :infinity), do: value
  defp min_limit(value, other), do: min(value, other)

  # A parse rule is a tag, optionally paired with the attributes to give the
  # node — a fixed map, or a function of the element's HTML attributes.
  defp normalize_parse(rules) do
    Enum.map(rules, fn
      tag when is_binary(tag) ->
        {tag, %{}}

      {tag, attrs}
      when is_binary(tag) and
             (is_map(attrs) or is_function(attrs, 1) or is_function(attrs, 2)) ->
        {tag, attrs}

      other ->
        raise ArgumentError,
              "invalid parse rule #{inspect(other)}: expected a tag, or a {tag, attrs} " <>
                "pair whose attrs is a map, or a function of the element's " <>
                "attributes and optionally its text"
    end)
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
