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

  ## Two boundaries, not one

  `validate/2` is the boundary at the keyboard, and it is strict on purpose:
  an unknown node type, an unknown mark, an unknown attribute or an attribute
  failing its validator all reject the document, and say where. Nothing
  outside the schema reaches the database, so rendering never has to escape
  its way out of untrusted markup. This is what storing the document buys
  over storing HTML and filtering tags on the way in.

  `sanitize/2` is the boundary at the screen. Stored documents are *not*
  re-validated when they are read, so a row written under a looser schema, or
  by a direct SQL write, is not covered by the paragraph above. Put it
  through `sanitize/2` before rendering it anywhere a reader will see.

  ## Validation is also normalisation

  What comes back from `validate/2` is canonical: the same rich text always
  produces the same document, byte for byte, which is what makes `hash/2`
  worth storing.

    * marks are sorted into the schema's declaration order, not the order the
      editor happened to add them in
    * an attribute left at its schema default is not written out, so two
      editors that disagree on whether to send `align: "left"` still store
      the same thing
    * adjacent text nodes carrying the same marks are merged

  A renderer therefore reads attributes with the schema default in hand —
  `Coelho.Render.attr/3` is the one place that knows the shape.

  ## Untrusted input

  `validate/2` is the boundary a hostile document hits first, so it is
  written to survive one: node type names are resolved against the schema
  rather than converted to atoms, the schema's `:limits` are checked before
  anything is allocated, and error paths are accumulated in reverse so that
  validating a deep document stays linear in its size.

  ## What is not a document

  `nil`, `""` and any other non-map are rejected with a single error,
  `expected an object`, on the empty path. `%{}` is rejected with
  `missing "type"`. None of them raise, and none of them are quietly treated
  as the empty document — `Coelho.empty/1` is how you ask for that. Casting
  a form field is the one place where an empty string means "no document",
  and `Coelho.Ecto.Type` and `Coelho.Ash.Type` handle it there, before
  validation.
  """

  @sanitize_passes 8

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
    [:coelho, :validate]
    |> Coelho.Telemetry.span(
      fn -> %{schema: Schema.fingerprint(schema)} end,
      fn -> do_validate(document, schema) end,
      &measurements/1
    )
    |> answer()
  end

  # Everything the metadata says is already known: the bounds check counts the
  # nodes and the characters on its way past them, so nothing here walks the
  # document a second time to report on it.
  defp measurements({:ok, _document, {nodes, text_length}}),
    do: %{result: :ok, errors: 0, nodes: nodes, text_length: text_length}

  defp measurements({:error, errors}), do: %{result: :error, errors: length(errors)}

  defp answer({:ok, document, _counted}), do: {:ok, document}
  defp answer(other), do: other

  defp do_validate(document, %Schema{} = schema) do
    with {:ok, counted} <- check_limits(document, schema.limits),
         {:ok, document, version_errors} <- check_version(document, schema) do
      {normalised, type, errors} = validate_node(document, schema, [], :all, 0)

      root_errors =
        if type != nil and type != schema.top_node do
          [error([], "document must be a #{schema.top_node}, got #{type}")]
        else
          []
        end

      case version_errors ++ root_errors ++ errors do
        [] -> {:ok, stamp_version(normalised, schema), counted}
        errors -> {:error, errors}
      end
    end
  end

  @doc """
  Extracts the plain text of a document, for full text search.

  Bullets are materialised, blocks are separated, and a node with a
  `:to_text` in its spec contributes whatever that says — an attachment its
  caption or its filename, a hard break a newline. What comes out reads like
  the document, which is what a search index wants and what
  `text_length/1` deliberately does not count.

  ## Indexing it

  A `jsonb` document is not searchable as it stands: an index over it can
  answer "does this key exist", never "does this say *tomato*". The text has
  to become a column of its own, written when the document is:

      # migration
      alter table(:posts) do
        add :body_text, :text
      end

      create index(:posts, ["body_text gin_trgm_ops"], using: :gin)

      # changeset
      def changeset(post, attrs) do
        post
        |> cast(attrs, [:body])
        |> put_body_text()
      end

      defp put_body_text(changeset) do
        case fetch_change(changeset, :body) do
          {:ok, document} -> put_change(changeset, :body_text, Coelho.to_text(document))
          :error -> changeset
        end
      end

  Derived at write time and not read time, because the alternative is
  extracting the text of every row on every search. A generated column would
  do as well where the database can call out to nothing — PostgreSQL cannot
  run this from SQL, so the application writes it.

  Two things follow. The column is a *derivative*, so it is never the source:
  a migration that changes what `to_text/2` produces means rewriting it, the
  same way any denormalisation does. And it holds no markup at all, which is
  what makes `to_tsvector` and trigram search behave — indexing rendered HTML
  matches on `strong` and `href`.
  """
  @spec to_text(map(), Schema.t()) :: String.t()
  def to_text(document, %Schema{} = schema) do
    document
    |> text_iodata(schema)
    |> IO.iodata_to_binary()
    |> strip_block_terminator()
  end

  @doc """
  Turns any term into a document the schema accepts, without failing.

  `validate/2` is the boundary at the keyboard: it says no, and says where.
  This is the boundary at the screen. Stored documents are not re-validated
  when they are read — `Coelho.Ecto.Type` deliberately trusts the column —
  so a row written under a looser schema, by a direct SQL write, or by a
  version of the application that has since tightened its vocabulary, would
  otherwise reach a public page unchecked.

  Nothing is reported and nothing is raised: what falls outside the schema is
  removed, and what is left is a document `validate/2` accepts. A hostile
  document becomes a poor document, never an unexpected rendering.

  What removal means, from the gentlest repair to the harshest:

    * a key the schema does not know is dropped
    * an attribute failing its validator is dropped, so the schema default
      applies — a heading claiming `level: 99` renders as a level 1 heading
    * a mark that is unknown, not allowed here, or whose own attributes fail
      is dropped, and the text it covered stays — a link with a
      `javascript:` href becomes plain text
    * a node whose type is unknown, or whose content cannot satisfy its
      content expression, is dropped whole, along with the text inside it
    * a document over the schema's bounds is **cut to fit** them: text past
      `:max_text_length` is truncated, nodes past `:max_nodes` are cut off,
      and what is nested deeper than `:max_depth` is dropped — the rest of
      the document stays either way
    * a document that cannot be repaired at all becomes `Coelho.empty/1`

  A document stamped with another schema version is repaired against this
  schema and restamped with its version, rather than refused the way
  `validate/2` refuses it. Rendering a document written under an older
  vocabulary badly beats rendering it as nothing; migrating it properly is
  `Coelho.migrate/2`.

  It is idempotent: a document that already validates comes back normalised
  and unchanged, and sanitising twice is sanitising once.

      Coelho.Document.sanitize(row.body, MyApp.RichText.schema())
      |> Coelho.Render.to_html(MyApp.RichText.schema())

  ## Bounds this call does not want

  `:limits` overrides the schema's for this call alone. A bound is a bound
  on *writing* — the browser posts into a hidden field no `maxlength`
  constrains, which is what `:max_text_length` is there to refuse — and
  reading is a different question: what is already stored is stored, and
  cutting it to fit on the way to the page loses text nobody asked to lose.

      Coelho.Document.sanitize(row.body, schema, limits: [max_text_length: :infinity])

  So an application that wants the structure cleaned and the length left
  alone says so here, instead of keeping a second schema per field to
  sanitise against. Judging the length itself is then its own to do, with
  the whole document in hand to do it on.

  """
  @spec sanitize(term(), Schema.t(), keyword()) :: map()
  def sanitize(document, %Schema{} = schema, opts \\ []) do
    schema = with_limits(schema, Keyword.get(opts, :limits, []))

    document
    |> reshape(schema.limits.max_depth, 0)
    |> trim(schema.limits, {0, 0})
    |> elem(0)
    |> repair(schema, @sanitize_passes)
  end

  # The fingerprint is deliberately left as the declared schema's: it names
  # the vocabulary, which this has not touched, and re-stamping would hash
  # the whole export on a path that runs once per rendered document.
  defp with_limits(schema, []), do: schema

  defp with_limits(schema, given),
    do: %{schema | limits: Schema.build_limits(schema.limits, given)}

  @doc """
  The number of characters a writer typed.

  This is the concatenation of the text nodes, nothing else: no bullet, no
  blank line between paragraphs, no filename standing in for an attachment.
  `to_text/2` materialises all of those because full text search wants them,
  and a length counted on its result rejects a document the editor still
  shows as under the limit — with nothing on screen to explain the gap.

  The browser half counts the same way, so the editor's counter and the
  server's check agree on the number.
  """
  @spec text_length(term()) :: non_neg_integer()
  def text_length(document), do: text_length(document, 0)

  defp text_length(%{"content" => content}, acc) when is_list(content),
    do: Enum.reduce(content, acc, &text_length/2)

  defp text_length(%{"text" => text}, acc) when is_binary(text), do: acc + String.length(text)
  defp text_length(_node, acc), do: acc

  @doc """
  Whether a document would put anything on the page.

  What an application asks before deciding to render a block at all — a
  portal panel, an announcement, a set of opening hours — where an empty
  document should mean the block is not there rather than a heading with
  nothing under it.

  The obvious stand-in, `text_length(document) == 0`, is wrong, and wrong in
  the direction that loses content: a document holding one image, or one
  attachment, has no text and is very much not blank. So the question is put
  to the schema instead — a node it declares `void: true` renders an element
  of its own and counts, whatever text it has none of.

      Coelho.blank?(page.intro_doc, MyApp.RichText.schema())

  Blank means: no text anywhere, and no void node with anything to show.
  Empty paragraphs and empty lists are blank, however many of them there are,
  and so is a paragraph of nothing but hard breaks — an inline void node
  declaring no attributes is punctuation between words, which is what a
  pasted-then-emptied field usually leaves behind. An image or an attachment
  has a source to point at, and a horizontal rule draws a line; all three
  count.

  This is a narrower question than the one `hash/2` answers with `nil`, which
  is "was there anything to agree to" and needs no schema. The two differ
  only on a document whose whole content is an attribute-less void node — a
  horizontal rule and nothing else is blank to `hash/2` and not blank here,
  because it does put a line on the page.
  """
  @spec blank?(term(), Schema.t()) :: boolean()
  def blank?(document, %Schema{} = schema \\ Schema.default()), do: not visible?(document, schema)

  defp visible?(node, schema) when is_map(node) do
    cond do
      is_binary(Map.get(node, "text")) and Map.get(node, "text") != "" -> true
      void?(node, schema) -> true
      true -> node |> Map.get("content", []) |> visible_child?(schema)
    end
  end

  defp visible?(_node, _schema), do: false

  defp visible_child?(children, schema) when is_list(children),
    do: Enum.any?(children, &visible?(&1, schema))

  defp visible_child?(_children, _schema), do: false

  defp void?(node, schema) do
    case Schema.spec_of(schema, node) do
      {:ok, %NodeSpec{void: true} = spec} -> not punctuation?(spec)
      _other -> false
    end
  end

  # An inline void node declaring no attributes has nothing to show and
  # nothing to say: a hard break is punctuation between words, not content.
  # A block one — a horizontal rule — draws a line, and an inline one with
  # attributes — an image — has a source to point at.
  #
  # It matters because a paste often normalises an emptied field to a
  # paragraph holding one break, and a document that is one break would
  # otherwise render a heading with nothing under it.
  defp punctuation?(%NodeSpec{inline: true, attrs: attrs}), do: attrs == %{}
  defp punctuation?(_spec), do: false

  @doc """
  A byte-for-byte stable serialisation of a document.

  Two documents describing the same rich text serialise identically, which
  is what `hash/2` needs and what a plain JSON encoding cannot promise: map
  key order is not part of a map, and `jsonb` reorders keys of its own
  accord.

  Three things make it stable, and all three are already true of a document
  `validate/2` returned:

    * object keys are emitted in sorted order
    * marks are in the schema's declaration order, not the order the editor
      added them
    * attributes left at their schema default are absent, not written out

  Which is why this must be given a **validated** document. Serialising what
  came back from the database instead — where a `jsonb` round trip has
  reordered the keys and an older writer may have spelled the defaults out —
  answers a different question, and answers it differently on two rows that
  hold the same text.
  """
  @spec canonical(term()) :: binary()
  def canonical(document), do: document |> encode() |> IO.iodata_to_binary()

  @doc """
  The hex digest of `canonical/1`, or `nil` for a document with nothing in it.

  What makes a proof of acceptance hold: store the digest of the terms the
  reader agreed to, and a later document that hashes the same is the same
  document, whatever the editor or the database did to the key order in
  between.

      iex> document = %{"type" => "doc", "content" => [
      ...>   %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hi"}]}
      ...> ]}
      iex> {:ok, document} = Coelho.validate(document)
      iex> Coelho.Document.hash(document)
      "00dc4439f0dcbb463ab186b5b8f81b68e50d70a7b1e3538b86a13e532a17a65d"

  A document is *empty* when it holds no text and no node carrying
  attributes — an empty paragraph, or a top node with no children. Note that
  a document whose only content is a horizontal rule counts as empty by that
  rule: it has nothing to agree to.

  Hash a validated document, for the reason `canonical/1` gives.
  """
  @spec hash(term(), :sha256 | :sha512 | :sha384 | :sha224 | :sha) :: String.t() | nil
  def hash(document, algorithm \\ :sha256) do
    if empty?(document) do
      nil
    else
      algorithm |> :crypto.hash(canonical(document)) |> Base.encode16(case: :lower)
    end
  end

  defp empty?(node) when is_map(node) do
    Map.get(node, "text", "") == "" and Map.get(node, "attrs", %{}) == %{} and
      node
      |> Map.get("content", [])
      |> then(&(is_list(&1) and Enum.all?(&1, fn c -> empty?(c) end)))
  end

  defp empty?(_node), do: true

  # -- Canonical encoding ---------------------------------------------------

  # A document is a closed shape — string keys, strings, whatever an
  # attribute validator lets through — so this is total rather than a JSON
  # encoder with an escape hatch. Sorting keys is the whole point; without it
  # the same document serialises two ways and the digest means nothing.
  defp encode(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, value} -> [encode(to_string(key)), ":", encode(value)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp encode(list) when is_list(list),
    do: ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp encode(value) when is_atom(value), do: encode(Atom.to_string(value))
  defp encode(value) when is_binary(value), do: [?", escape_json(value), ?"]

  defp escape_json(value) do
    for <<byte <- value>>, into: <<>>, do: escape_byte(byte)
  end

  defp escape_byte(?"), do: "\\\""
  defp escape_byte(?\\), do: "\\\\"
  defp escape_byte(?\n), do: "\\n"
  defp escape_byte(?\r), do: "\\r"
  defp escape_byte(?\t), do: "\\t"
  defp escape_byte(byte) when byte < 0x20, do: "\\u" <> Base.encode16(<<0, byte>>, case: :lower)
  defp escape_byte(byte), do: <<byte>>

  # -- Sanitising -----------------------------------------------------------

  # Everything the schema cannot name is taken out before validation runs, so
  # that the repair below only ever has to deal with real structural
  # problems. Dropping a whole paragraph because someone left a stray key on
  # it would be the harshest possible answer to the mildest possible fault.
  defp reshape(node, max_depth, depth) when is_map(node) do
    if over?(depth, max_depth) do
      %{}
    else
      # `schema_version` goes with everything else the schema cannot name.
      # A document stamped with an older version is repaired against
      # *today's* schema and restamped, which is the poor-document outcome
      # this function promises — refusing it here would turn a page that
      # renders badly into a page that renders empty. Migrating it properly
      # is `Coelho.migrate/2`, and that is a deliberate act.
      node
      |> Map.take(@node_keys)
      |> reshape_field("attrs", &is_map/1, %{})
      |> reshape_field("marks", &is_list/1, [])
      |> reshape_marks()
      |> reshape_content(max_depth, depth)
    end
  end

  defp reshape(_node, _max_depth, _depth), do: %{}

  defp reshape_field(node, key, valid?, empty) do
    case Map.fetch(node, key) do
      {:ok, value} -> if valid?.(value), do: node, else: Map.put(node, key, empty)
      :error -> node
    end
  end

  defp reshape_marks(node) do
    case Map.fetch(node, "marks") do
      {:ok, marks} ->
        Map.put(node, "marks", Enum.map(marks, &(&1 |> reshape_mark() |> Map.take(@mark_keys))))

      :error ->
        node
    end
  end

  defp reshape_mark(mark) when is_map(mark), do: reshape_field(mark, "attrs", &is_map/1, %{})
  defp reshape_mark(_mark), do: %{}

  # An empty map is what `reshape/3` answers with for a child it cannot keep
  # at all: nested past `:max_depth`, or not a map to begin with. Dropping it
  # here rather than leaving it in the content is what makes the depth bound
  # *cut to fit* like the other two — left in, it is still a node at a depth
  # the bound refuses, so `check_limits/2` fails at the root, and the only
  # repair at the root is replacing the document. One bullet indented a level
  # too far took every paragraph beside it.
  defp reshape_content(node, max_depth, depth) do
    case Map.fetch(node, "content") do
      {:ok, content} when is_list(content) ->
        kept =
          content
          |> Enum.map(&reshape(&1, max_depth, depth + 1))
          |> Enum.reject(&(&1 == %{}))

        Map.put(node, "content", kept)

      {:ok, _other} ->
        Map.delete(node, "content")

      :error ->
        node
    end
  end

  # The repair is driven by validation itself rather than by a second
  # traversal that would have to reimplement — and drift from — every rule
  # `validate/2` enforces. Each pass removes what the errors point at and
  # asks again; every pass strictly shrinks the document, so this terminates
  # well before the cap, and the cap is there only so that a rule we get
  # wrong later fails safe rather than spinning.
  # The first pass is the sanitisation's `[:coelho, :validate]` event; the
  # passes that follow are the repair talking to itself, and each one used to
  # emit a span of its own — up to eight events, and eight spans' worth of
  # metadata, for one sanitised document.
  defp repair(document, schema, @sanitize_passes = passes),
    do: repair(validate(document, schema), document, schema, passes)

  defp repair(document, schema, passes),
    do: repair(document |> do_validate(schema) |> answer(), document, schema, passes)

  defp repair(validated, document, schema, passes) do
    case validated do
      {:ok, document} ->
        document

      {:error, _errors} when passes <= 0 ->
        empty_document(schema)

      {:error, errors} ->
        case prune(document, errors) do
          :root -> empty_document(schema)
          ^document -> escalate(document, schema, errors, passes)
          pruned -> repair(pruned, schema, passes - 1)
        end
    end
  end

  # The gentle repair for an error is chosen from its path, and a path can
  # describe something that is not there to remove — a *missing* required
  # attribute reads `content[0].attrs.src`, and dropping `src` from a node
  # that never had it changes nothing. Left alone, the pass count runs out
  # and a document with one bad image comes back empty, taking every good
  # paragraph with it.
  #
  # So a pass that removed nothing is not repeated: the nodes the errors
  # point at go instead.
  defp escalate(document, schema, errors, passes) do
    case prune(document, errors, :node) do
      :root -> empty_document(schema)
      ^document -> empty_document(schema)
      pruned -> repair(pruned, schema, passes - 1)
    end
  end

  defp empty_document(schema) do
    case validate(Coelho.empty(schema), schema) do
      {:ok, document} -> document
      {:error, _errors} -> %{"type" => Atom.to_string(schema.top_node)}
    end
  end

  # An error that names no node — the top node's own content expression, for
  # one — used to empty the document on its own, throwing away every repair
  # its siblings had located. It is the answer of last resort instead: a
  # content expression that does not match is usually the *consequence* of
  # the children that failed beside it, and removing those is what makes it
  # match.
  defp prune(document, errors, how \\ :gently) do
    operations =
      for error <- errors,
          {:ok, path, action} <- [instruction(error.path, how)],
          do: {path, action}

    case operations do
      [] -> :root
      operations -> apply_operations(document, operations)
    end
  end

  # An error path reads `content[0].marks[1].attrs.href`. The leading
  # `content`/index pairs address a node; what follows says how gently the
  # node can be repaired. A bad attribute on a mark takes the mark, not the
  # node, because the text under the mark is the part worth keeping.
  defp instruction(path, :node) do
    path |> split_path([]) |> elem(0) |> drop_self()
  end

  defp instruction(path, :gently) do
    {indices, tail} = split_path(path, [])

    case tail do
      ["attrs", key] -> {:ok, indices, {:drop_attr, key}}
      ["attrs"] -> {:ok, indices, :drop_attrs}
      ["marks", index | _rest] when is_integer(index) -> {:ok, indices, {:drop_mark, index}}
      ["marks" | _rest] -> {:ok, indices, :drop_marks}
      _other -> drop_self(indices)
    end
  end

  defp split_path(["content", index | rest], indices) when is_integer(index),
    do: split_path(rest, [index | indices])

  defp split_path(tail, indices), do: {Enum.reverse(indices), tail}

  defp drop_self([]), do: :root

  defp drop_self(indices) do
    {parent, [last]} = Enum.split(indices, -1)
    {:ok, parent, {:drop_child, last}}
  end

  # Children are removed last. Both the recursion below and the indices in the
  # error paths address the *original* list, so taking a child out first
  # would shift every index after it and repair the wrong node.
  defp apply_operations(node, operations) do
    {here, deeper} = Enum.split_with(operations, fn {path, _action} -> path == [] end)
    actions = Enum.map(here, &elem(&1, 1))

    node
    |> apply_here(actions)
    |> apply_deeper(deeper)
    |> drop_children(for {:drop_child, index} <- actions, into: MapSet.new(), do: index)
  end

  defp apply_here(node, actions) do
    dropped_attrs = for {:drop_attr, key} <- actions, do: key
    dropped_marks = for {:drop_mark, index} <- actions, into: MapSet.new(), do: index

    node
    |> then(&if(:drop_attrs in actions, do: Map.delete(&1, "attrs"), else: &1))
    |> then(&if(:drop_marks in actions, do: Map.delete(&1, "marks"), else: &1))
    |> update_existing("attrs", &Map.drop(&1, dropped_attrs))
    |> update_existing("marks", &reject_indices(&1, dropped_marks))
  end

  defp drop_children(node, indices) do
    if Enum.empty?(indices) do
      node
    else
      update_existing(node, "content", &reject_indices(&1, indices))
    end
  end

  defp apply_deeper(node, operations) do
    grouped =
      Enum.group_by(
        operations,
        fn {[index | _rest], _action} -> index end,
        fn {[_index | rest], action} -> {rest, action} end
      )

    update_existing(node, "content", fn content ->
      content
      |> Enum.with_index()
      |> Enum.map(fn {child, index} ->
        case Map.fetch(grouped, index) do
          {:ok, child_operations} -> apply_operations(child, child_operations)
          :error -> child
        end
      end)
    end)
  end

  defp update_existing(node, key, fun) do
    case Map.fetch(node, key) do
      {:ok, value} -> Map.put(node, key, fun.(value))
      :error -> node
    end
  end

  defp reject_indices(list, indices) do
    list
    |> Enum.with_index()
    |> Enum.reject(fn {_item, index} -> MapSet.member?(indices, index) end)
    |> Enum.map(&elem(&1, 0))
  end

  # -- Limits ---------------------------------------------------------------

  # What `sanitize/3` does about a document over the bounds, and it is worth
  # saying why it is not simply left to the repair below. A bound is
  # reported with an empty path — it is the *document* that is too long, no
  # node in it is — and the only repair at the root is replacing the root.
  # So an over-long document came back empty: every paragraph of a
  # thirteen-thousand-character terms and conditions thrown away because the
  # schema said twelve thousand, and the length guard that measured what
  # came back then saw zero and said nothing.
  #
  # Cutting to fit is the repair that loses least. `reshape/3` makes the same
  # one for `:max_depth`, by dropping what is nested past it.
  #
  # The count is `check_limits/2`'s, node for node — the empty maps
  # `reshape/3` leaves behind included — or the trimmed document would fail
  # the check it was trimmed to pass and be emptied after all.
  defp trim(node, limits, {nodes, text} = acc) when is_map(node) do
    value = Map.get(node, "text")
    room = room(limits.max_text_length, text)

    cond do
      over?(nodes + 1, limits.max_nodes) ->
        {nil, acc}

      is_binary(value) and room == 0 ->
        {nil, acc}

      is_binary(value) ->
        {kept, acc} = keep_text(node, value, room, {nodes + 1, text})
        trim_content(kept, limits, acc)

      true ->
        trim_content(node, limits, {nodes + 1, text})
    end
  end

  defp trim(node, _limits, acc), do: {node, acc}

  defp room(:infinity, _text), do: :infinity
  defp room(max, text), do: max(max - text, 0)

  defp keep_text(node, value, :infinity, {nodes, text}),
    do: {node, {nodes, text + String.length(value)}}

  defp keep_text(node, value, room, {nodes, text}) do
    length = String.length(value)

    if length <= room do
      {node, {nodes, text + length}}
    else
      {Map.put(node, "text", String.slice(value, 0, room)), {nodes, text + room}}
    end
  end

  # A child dropped for the node bound takes its siblings with it, since
  # nothing after it would fit either. Saying so with a reduce that keeps
  # answering `nil` is the same answer for a fraction of the words.
  defp trim_content(node, limits, acc) do
    case Map.get(node, "content") do
      children when is_list(children) ->
        {kept, acc} =
          Enum.reduce(children, {[], acc}, fn child, {kept, acc} ->
            case trim(child, limits, acc) do
              {nil, acc} -> {kept, acc}
              {child, acc} -> {[child | kept], acc}
            end
          end)

        {Map.put(node, "content", Enum.reverse(kept)), acc}

      _other ->
        {node, acc}
    end
  end

  # The bound has to be checked before validation, not during it: a document
  # arrives in a hidden form field with no `maxlength` to speak of, and
  # validating a million nodes to then say there were too many is the
  # allocation the bound exists to refuse. This walk touches each node once,
  # allocates nothing, and stops at the first breach.
  defp check_limits(document, limits) do
    case measure(document, limits, 0, {0, 0}) do
      {:ok, counted} -> {:ok, counted}
      {:error, message} -> {:error, [error([], message)]}
    end
  end

  defp measure(node, limits, depth, {nodes, text}) when is_map(node) do
    cond do
      over?(depth, limits.max_depth) ->
        {:error, "document is nested more than #{limits.max_depth} levels deep"}

      over?(nodes + 1, limits.max_nodes) ->
        {:error, "document holds more than #{limits.max_nodes} nodes"}

      true ->
        measure_text(node, limits, depth, {nodes + 1, text})
    end
  end

  defp measure(_node, _limits, _depth, acc), do: {:ok, acc}

  defp measure_text(node, limits, depth, {nodes, text}) do
    case Map.get(node, "text") do
      value when is_binary(value) ->
        # Counted, never estimated. A byte count is an *upper* bound on the
        # character count, so refusing on `byte_size` alone rejects a
        # perfectly legal document the moment it is not ASCII — seven
        # accented letters are fourteen bytes, and a CJK document reaches
        # the shipped bound at a third of the characters it is allowed.
        text = text + String.length(value)

        if over?(text, limits.max_text_length) do
          {:error, "document holds more than #{limits.max_text_length} characters of text"}
        else
          measure_content(node, limits, depth, {nodes, text})
        end

      _other ->
        measure_content(node, limits, depth, {nodes, text})
    end
  end

  defp measure_content(node, limits, depth, acc) do
    case Map.get(node, "content") do
      children when is_list(children) ->
        Enum.reduce_while(children, {:ok, acc}, fn child, {:ok, acc} ->
          case measure(child, limits, depth + 1, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      _other ->
        {:ok, acc}
    end
  end

  defp over?(_value, :infinity), do: false
  defp over?(value, limit), do: value > limit

  # -- Schema version -------------------------------------------------------

  # A document that does not say which schema wrote it cannot be migrated
  # when the schema moves: there is no way to tell a node that was renamed
  # from one that was never there. `RichDoc`'s `v` field has exactly that
  # defect — written on every save, read by nothing.
  #
  # So the key is only written by a schema that declares a version, and a
  # document stamped with a different one is an error rather than something
  # to guess at. `Coelho.migrate/2` is the deliberate move between the two.
  defp check_version(document, %Schema{version: nil}) when is_map(document) do
    if Map.has_key?(document, "schema_version") do
      # Taken out before the unknown-key check runs, so the answer is the one
      # sentence that explains the situation rather than that sentence and a
      # generic one underneath it.
      {:ok, Map.delete(document, "schema_version"),
       [
         error(
           [],
           ~s(document carries "schema_version" but the schema declares no version)
         )
       ]}
    else
      {:ok, document, []}
    end
  end

  defp check_version(document, %Schema{version: version}) when is_map(document) do
    case Map.fetch(document, "schema_version") do
      {:ok, ^version} ->
        {:ok, Map.delete(document, "schema_version"), []}

      :error ->
        {:ok, document, []}

      {:ok, other} ->
        {:ok, Map.delete(document, "schema_version"),
         [
           error(
             [],
             "document was written under schema version #{inspect(other)}, " <>
               "and this schema is version #{version}; see Coelho.migrate/2"
           )
         ]}
    end
  end

  defp check_version(document, _schema), do: {:ok, document, []}

  defp stamp_version(document, %Schema{version: nil}), do: document

  defp stamp_version(document, %Schema{version: version}),
    do: Map.put(document, "schema_version", version)

  # -- Validation -----------------------------------------------------------

  # Paths are accumulated reversed and turned around once, when an error is
  # built. Appending to the path at every level instead makes validation
  # quadratic in document depth, which is a denial of service on input that
  # is untrusted by definition.
  #
  # Returns `{normalised_node, type, errors}`. `type` is nil when the node
  # could not be resolved, which tells the caller to skip the content
  # expression check rather than pile a second, meaningless error on top.
  defp validate_node(_node, %Schema{limits: %{max_depth: max}}, rpath, _allowed_marks, depth)
       when is_integer(max) and depth > max do
    {nil, nil, [error(rpath, "document is nested more than #{max} levels deep")]}
  end

  defp validate_node(node, schema, rpath, allowed_marks, depth) when is_map(node) do
    with {:ok, type} <- fetch_type(node, schema, rpath),
         %NodeSpec{} = spec <- Schema.node_spec(schema, type) do
      unknown_errors = unknown_key_errors(node, @node_keys, rpath)
      {attrs, attr_errors} = validate_attrs(node, spec, rpath)
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

  defp validate_attrs(node, spec, rpath) do
    %{attrs: specs} = spec
    known = Schema.attr_keys(spec)
    given = Map.get(node, "attrs", %{})

    if is_map(given) do
      # Reported at the offending key rather than at `attrs`, because the
      # path is what `sanitize/2` repairs from: an error at `attrs` takes
      # every attribute on the node with it, so one stray key would cost a
      # heading its level.
      unknown =
        for {key, _} <- given,
            not MapSet.member?(known, key),
            do: error([key, "attrs" | rpath], "unknown attribute #{inspect(key)}")

      {attrs, errors} = Enum.reduce(specs, {%{}, []}, &validate_attr(&1, &2, given, rpath))

      {attrs, unknown ++ Enum.reverse(errors)}
    else
      {%{}, [error(["attrs" | rpath], "expected an object")]}
    end
  end

  defp validate_attr({name, %Attr{} = spec}, {attrs, errors}, given, rpath) do
    key = Atom.to_string(name)
    attr_rpath = [key, "attrs" | rpath]

    case Map.fetch(given, key) do
      {:ok, value} -> put_attr(attrs, errors, key, value, spec, attr_rpath)
      :error when spec.required -> {attrs, [error(attr_rpath, "is required") | errors]}
      :error -> {attrs, errors}
    end
  end

  # An attribute left at its default is not written. Two editors that agree
  # on what the writer typed would otherwise store different documents —
  # whichever of them bothered to send `align: "left"` — and hash
  # differently. Readers never see the difference: a renderer asks for an
  # attribute with the schema default in hand, and the browser fills defaults
  # from the exported schema. What it buys, measured on documents whose nodes
  # are mostly plain paragraphs, is the `"attrs":{...}` object on every one
  # of them.
  defp put_attr(attrs, errors, key, value, spec, attr_rpath) do
    case Attr.validate(spec.validate, value) do
      :ok when not spec.required and value === spec.default -> {attrs, errors}
      :ok -> {Map.put(attrs, key, compact(value)), errors}
      {:error, message} -> {attrs, [error(attr_rpath, message) | errors]}
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
          validate_mark_list(marks, allowed_marks, schema, rpath)
        else
          {[], [error(["marks" | rpath], "marks are only allowed on inline nodes")]}
        end

      _other ->
        {[], [error(["marks" | rpath], "expected a list")]}
    end
  end

  defp validate_mark_list(marks, allowed_marks, schema, rpath) do
    marks
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {mark, index}, {kept, errors} ->
      case validate_mark(mark, allowed_marks, schema, [index, "marks" | rpath]) do
        {:ok, mark} -> {add_mark(kept, mark), errors}
        {:error, mark_errors} -> {kept, [mark_errors | errors]}
      end
    end)
    |> then(fn {kept, errors} -> {sort_marks(kept, schema), concat_reversed(errors)} end)
  end

  # Marks are a set, so the order the editor happened to add them in carries
  # no meaning — and two identical fragments that disagree on it would hash
  # differently, which is the whole point of `hash/2` gone. Sorting by the
  # schema's declaration order is what ProseMirror itself does when it ranks
  # marks, so the document the browser holds and the one stored agree.
  defp sort_marks(marks, schema) do
    marks
    |> Enum.reverse()
    |> Enum.sort_by(&mark_rank(schema, &1))
  end

  defp mark_rank(schema, %{"type" => type}) do
    case Schema.resolve_mark_name(schema, type) do
      {:ok, name} -> Schema.mark_index(schema, name)
      :error -> length(schema.mark_order)
    end
  end

  defp validate_mark(mark, allowed_marks, schema, rpath) when is_map(mark) do
    with {:ok, type} <- fetch_mark_type(mark, rpath),
         {:ok, name} <- resolve_mark(schema, type, rpath),
         :ok <- mark_allowed(allowed_marks, name, type, rpath) do
      spec = Schema.mark_spec(schema, name)
      {attrs, errors} = validate_attrs(mark, spec, rpath)

      case unknown_key_errors(mark, @mark_keys, rpath) ++ errors do
        [] -> {:ok, put_unless_empty(%{"type" => Atom.to_string(name)}, "attrs", attrs)}
        errors -> {:error, errors}
      end
    end
  end

  defp validate_mark(_mark, _allowed_marks, _schema, rpath),
    do: {:error, [error(rpath, "expected an object")]}

  defp fetch_mark_type(mark, rpath) do
    case Map.fetch(mark, "type") do
      {:ok, type} -> {:ok, type}
      :error -> {:error, [error(rpath, ~s(missing "type"))]}
    end
  end

  # Naming the mark is the whole value of the message: a document rejected
  # for a mark that a narrowed schema no longer has says which one, so the
  # answer is "this field does not allow italics" rather than "invalid".
  defp resolve_mark(schema, type, rpath) do
    case Schema.resolve_mark_name(schema, type) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, [error(rpath, "unknown mark type #{inspect(type)}")]}
    end
  end

  defp mark_allowed(allowed_marks, name, type, rpath) do
    if Schema.mark_allowed?(allowed_marks, name) do
      :ok
    else
      {:error, [error(rpath, "mark #{inspect(type)} is not allowed on this node")]}
    end
  end

  # Marks are a set on the browser side, so the same mark twice is normalised
  # away rather than rejected — keeping it would store a document the editor
  # could never have produced.
  defp add_mark(kept, mark) do
    if Enum.any?(kept, &(&1["type"] == mark["type"])), do: kept, else: [mark | kept]
  end

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

        {merge_text(normalised), errors ++ content_errors(spec, children, types, schema, rpath)}

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

  # Two adjacent text nodes carrying the same marks are one run of text; the
  # browser side merges them on the spot, so a document that kept them apart
  # would render an extra element and grow one on every round trip.
  # The joined text is accumulated as iodata and flattened once: concatenating
  # into the run as it grows re-copies everything merged so far, which on a
  # paste that arrives as one text node per word is quadratic in the length
  # of the paragraph.
  defp merge_text(children) do
    children
    |> Enum.reduce([], fn
      %{"type" => "text"} = node, [%{"type" => "text"} = previous | rest] ->
        if Map.get(node, "marks", []) == Map.get(previous, "marks", []) do
          [%{previous | "text" => [previous["text"], node["text"]]} | rest]
        else
          [node, previous | rest]
        end

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
    |> Enum.map(&flatten_text/1)
  end

  defp flatten_text(%{"type" => "text", "text" => text} = node) when is_list(text),
    do: %{node | "text" => IO.iodata_to_binary(text)}

  defp flatten_text(node), do: node

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
    case Schema.spec_of(schema, node) do
      {:ok, spec} -> node_text(spec, node, schema)
      :error -> []
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
    match?({:ok, %NodeSpec{inline: false}}, Schema.spec_of(schema, child))
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
