defmodule Coelho.SchemaTest do
  use ExUnit.Case, async: true

  alias Coelho.Schema

  doctest Coelho.Schema

  # Everything a hot path would otherwise recompute is derived once, when the
  # schema is built. The three constructors converge on the same derivation,
  # so what this guards is that they all reach it — a new one that forgets to
  # would hand the editor a stale export and the renderer a stale rank.
  describe "derived fields" do
    test "carry the encoded export, and follow extend/2 and restrict/2" do
      schema = Schema.default()
      extended = Schema.extend(schema, marks: [highlight: [render: {"mark", []}]])
      restricted = Schema.restrict(schema, marks: [:bold])

      for built <- [schema, extended, restricted] do
        assert built.json == JSON.encode!(Schema.to_json(built))
        assert built.fingerprint == :erlang.phash2(Schema.to_json(built))
      end

      assert extended.json != schema.json
      assert restricted.json != schema.json
    end

    test "rank marks by declaration order, and unknown marks last" do
      schema = Schema.extend(Schema.default(), marks: [highlight: [render: {"mark", []}]])

      for {name, index} <- Enum.with_index(schema.mark_order) do
        assert Schema.mark_index(schema, name) == index
      end

      assert Schema.mark_index(schema, :nothing_of_the_sort) == length(schema.mark_order)
    end

    test "carry the empty document the schema's own validation accepts" do
      schema = Schema.new(nodes: [doc: [content: "note+"], note: [content: "text*"]])

      assert schema.empty == %{"type" => "doc", "content" => [%{"type" => "note"}]}
      assert {:ok, _document} = Coelho.Document.validate(schema.empty, schema)
      assert Coelho.empty(schema) == schema.empty
    end

    test "carry the tags the schema imports at all" do
      schema = Schema.default()

      assert MapSet.member?(schema.parse_tags, "p")
      assert MapSet.member?(schema.parse_tags, "strong")
      refute MapSet.member?(schema.parse_tags, "table")
    end

    test "carry each spec's attribute names as the strings a document uses" do
      schema = Schema.default()

      assert schema.nodes.heading.attr_keys == MapSet.new(["level", "align"])
      assert schema.marks.link.attr_keys == MapSet.new(["href", "title"])
    end

    test "are derived on the spot for a spec that never went through the build" do
      # Nothing in the library builds one by hand, but a derived field read
      # straight off the struct answers `nil` for anything that did — and a
      # `nil` reaching `MapSet.member?/2` raises where the old code worked.
      spec = %{Schema.node_spec(Schema.default(), :heading) | attr_keys: nil}

      assert Schema.attr_keys(spec) == MapSet.new(["level", "align"])

      assert Schema.parse_tags(%{Schema.default() | parse_tags: nil}) ==
               Schema.default().parse_tags

      assert Schema.empty(%{Schema.default() | empty: nil}) == Schema.default().empty
      assert Schema.json(%{Schema.default() | json: nil}) == Schema.default().json
    end

    test "rank marks off the declaration order when the ranks were never built" do
      # Ranking every mark the same is not a crash, it is a document that
      # stops normalising to the same bytes as the one the browser holds.
      schema = Schema.default()
      unstamped = %{schema | mark_ranks: %{}}

      for {name, index} <- Enum.with_index(schema.mark_order) do
        assert Schema.mark_index(unstamped, name) == index
      end

      assert Schema.mark_index(unstamped, :nothing_of_the_sort) == length(schema.mark_order)
    end
  end

  test "injects a text node when the declaration omits it" do
    schema = Schema.new(nodes: [doc: [content: "text*"]])

    assert %{text: %{inline: true, text: true}} = Map.take(schema.nodes, [:text])
    assert :text in schema.node_order
  end

  test "indexes groups" do
    schema = Schema.default()

    assert Schema.instance_of?(schema, :block, :paragraph)
    assert Schema.instance_of?(schema, :paragraph, :paragraph)
    refute Schema.instance_of?(schema, :block, :text)
    refute Schema.instance_of?(schema, :inline, :paragraph)
  end

  test "never turns an unknown type name into an atom" do
    schema = Schema.default()

    assert :error = Schema.resolve_node_name(schema, "definitely_not_a_node")
    assert :error = Schema.resolve_mark_name(schema, "definitely_not_a_mark")
    assert {:ok, :paragraph} = Schema.resolve_node_name(schema, "paragraph")
  end

  describe "new/1 consistency checks" do
    test "rejects an unparsable content expression" do
      assert_raise ArgumentError, ~r/invalid content expression/, fn ->
        Schema.new(nodes: [doc: [content: "block+("]])
      end
    end

    test "rejects a content expression naming nothing" do
      assert_raise ArgumentError, ~r/references :nowhere/, fn ->
        Schema.new(nodes: [doc: [content: "nowhere+"]])
      end
    end

    test "rejects an unknown mark in a node's allow list" do
      assert_raise ArgumentError, ~r/unknown mark :bold/, fn ->
        Schema.new(nodes: [doc: [content: "text*", marks: [:bold]]])
      end
    end

    test "rejects a missing top node" do
      assert_raise ArgumentError, ~r/top node :doc is not declared/, fn ->
        Schema.new(nodes: [paragraph: [content: "text*"]])
      end
    end
  end

  describe "to_json/1" do
    test "emits ordered pairs, since node order carries meaning in ProseMirror" do
      json = Schema.to_json(Schema.default())

      assert json["topNode"] == "doc"
      assert [["doc", _] | _] = json["nodes"]

      names = Enum.map(json["nodes"], &hd/1)
      assert names == Enum.map(Schema.default().node_order, &Atom.to_string/1)
    end

    test "carries content, group, attrs and atom flags" do
      json = Schema.to_json(Schema.default())
      nodes = Map.new(json["nodes"], fn [name, spec] -> {name, spec} end)

      assert nodes["doc"]["content"] == "block+"
      assert nodes["paragraph"]["group"] == "block"

      assert nodes["heading"]["attrs"] ==
               %{"level" => %{"default" => 1}, "align" => %{"default" => nil}}

      assert nodes["image"]["atom"] == true
      assert nodes["image"]["inline"] == true
      # A required attribute has no default, which is how ProseMirror spells it.
      assert nodes["image"]["attrs"]["src"] == %{}
    end

    test "spells 'no marks allowed' as an empty string" do
      json = Schema.to_json(Schema.default())
      nodes = Map.new(json["nodes"], fn [name, spec] -> {name, spec} end)

      assert nodes["code_block"]["marks"] == ""
      refute Map.has_key?(nodes["paragraph"], "marks")
    end

    test "a render that is a declaration is exported, so the browser can draw it" do
      json = Schema.to_json(Schema.default())
      marks = Map.new(json["marks"], fn [name, spec] -> {name, spec} end)
      nodes = Map.new(json["nodes"], fn [name, spec] -> {name, spec} end)

      assert marks["bold"]["renderDOM"] == ["strong", %{}, 0]
      assert nodes["paragraph"]["renderDOM"] == ["p", %{}, 0]
      # A void node has no content hole.
      assert nodes["horizontal_rule"]["renderDOM"] == ["hr", %{}]
    end

    test "a render that is a function cannot be, and says nothing rather than half of it" do
      json = Schema.to_json(Schema.default())
      nodes = Map.new(json["nodes"], fn [name, spec] -> {name, spec} end)

      # The tag depends on the level, so only Elixir can answer it.
      refute Map.has_key?(nodes["heading"], "renderDOM")
    end

    test "the spec's class is not folded into the render, since editorAttrs carries it" do
      schema =
        Schema.extend(Schema.default(),
          marks: [highlight: [class: "hl", render: {"mark", [{"class", "base"}]}]]
        )

      marks = Map.new(Schema.to_json(schema)["marks"], fn [name, spec] -> {name, spec} end)

      assert marks["highlight"]["renderDOM"] == ["mark", %{"class" => "base"}, 0]
      assert marks["highlight"]["editorAttrs"] == %{"class" => "hl"}
    end

    test "the attribute values the server renders, in the DOM's own spelling" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [
            details: [content: "inline*", group: "block", render: {"details", [{"open", true}]}],
            cell: [
              content: "inline*",
              group: "block",
              render: {"td", [{"colspan", 2}, {"hidden", false}]}
            ]
          ]
        )

      nodes = Map.new(Schema.to_json(schema)["nodes"], fn [name, spec] -> {name, spec} end)

      # A bare attribute is the empty string, which is what draws
      # `<details open>`; `false` writes nothing, exactly as the server
      # renders nothing for it.
      assert nodes["details"]["renderDOM"] == ["details", %{"open" => ""}, 0]
      assert nodes["cell"]["renderDOM"] == ["td", %{"colspan" => "2"}, 0]
    end

    test "a value neither half could write is refused rather than half exported" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [odd: [content: "inline*", group: "block", render: {"i", [{"data-x", {1, 2}}]}]]
        )

      nodes = Map.new(Schema.to_json(schema)["nodes"], fn [name, spec] -> {name, spec} end)

      refute Map.has_key?(nodes["odd"], "renderDOM")
    end

    test "parse rules with fixed attributes are exported too" do
      json = Schema.to_json(Schema.default())
      marks = Map.new(json["marks"], fn [name, spec] -> {name, spec} end)

      assert marks["bold"]["parseDOM"] == [["strong", %{}], ["b", %{}]]
    end

    test "a parse rule extracting with a function is left out rather than guessed at" do
      schema =
        Schema.new(
          nodes: [doc: [content: "text*"]],
          marks: [
            link: [attrs: [href: [required: true]], parse: [{"a", &Map.take(&1, ["href"])}]]
          ]
        )

      marks = Map.new(Schema.to_json(schema)["marks"], fn [name, spec] -> {name, spec} end)

      refute Map.has_key?(marks["link"], "parseDOM")
    end
  end

  describe "new/1 rejects duplicate declarations" do
    test "a node declared twice would emit an invalid ProseMirror schema" do
      assert_raise ArgumentError, ~r/node :paragraph is declared twice/, fn ->
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [content: "inline*", group: "block"],
            paragraph: [content: "text*", group: "block"]
          ]
        )
      end
    end

    test "a mark declared twice" do
      assert_raise ArgumentError, ~r/mark :bold is declared twice/, fn ->
        Schema.new(nodes: [doc: [content: "text*"]], marks: [bold: [], bold: []])
      end
    end
  end

  describe "attribute validators" do
    alias Coelho.Schema.Attr

    test "a validator returning something else fails as the schema bug it is" do
      assert_raise ArgumentError, ~r/expected :ok or \{:error, message\}/, fn ->
        Attr.validate(fn _ -> :nope end, "x")
      end
    end

    test "an unknown validator term is rejected" do
      assert_raise ArgumentError, ~r/unknown attribute validator/, fn ->
        Attr.validate(:definitely_not_a_validator, "x")
      end
    end
  end

  describe "parse rules" do
    test "a malformed rule names itself rather than crashing later" do
      assert_raise ArgumentError, ~r/invalid parse rule :p/, fn ->
        Schema.new(nodes: [doc: [content: "text*", parse: [:p]]])
      end

      assert_raise ArgumentError, ~r/invalid parse rule \{"a", "href"\}/, fn ->
        Schema.new(nodes: [doc: [content: "text*", parse: [{"a", "href"}]]])
      end
    end
  end

  describe "extend/2" do
    test "adds nodes after what was already there" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [
            mention: [
              group: "inline",
              inline: true,
              void: true,
              attrs: [user_id: [required: true, validate: :integer]]
            ]
          ]
        )

      assert List.last(schema.node_order) == :mention
      assert Schema.instance_of?(schema, :inline, :mention)
      assert Enum.take(schema.node_order, 2) == Enum.take(Schema.default().node_order, 2)
    end

    test "the extended schema validates and renders the new node" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [
            mention: [
              group: "inline",
              inline: true,
              void: true,
              attrs: [user_id: [required: true, validate: :integer]],
              render: {"span", [{"class", "mention"}]}
            ]
          ]
        )

      document = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "mention", "attrs" => %{"user_id" => 7}}]
          }
        ]
      }

      assert {:ok, document} = Coelho.validate(document, schema)
      # A void node is not an HTML void element: only the tags HTML closes by
      # itself are emitted unclosed, or a lone <span> would swallow the rest
      # of the paragraph in the browser's parser.
      assert Coelho.to_html(document, schema) == ~s(<p><span class="mention"></span></p>)
      # And the default schema still rejects it, which is the point of the copy.
      assert {:error, _} = Coelho.validate(document)
    end

    test "redeclaring a name adjusts it without a fork" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [paragraph: [content: "inline*", group: "block", render: {"div", []}]]
        )

      assert length(schema.node_order) == length(Schema.default().node_order)
      assert Schema.node_spec(schema, :paragraph).render == {"div", []}
    end

    test "what a redeclaration does not name is kept from the spec it adjusts" do
      # It used to be replaced outright, and the loss was silent: giving the
      # shipped `bold` a theme's class took its parse rules with it, so a
      # `<strong>` pasted out of a word processor came in as plain text with
      # nothing said about it anywhere.
      schema = Schema.extend(Schema.default(), marks: [bold: [class: "font-bold"]])

      assert Schema.mark_spec(schema, :bold).class == "font-bold"

      assert Schema.mark_spec(schema, :bold).parse ==
               Schema.mark_spec(Schema.default(), :bold).parse

      assert Schema.mark_spec(schema, :bold).render == {"strong", []}
    end

    test "a node keeps its content, group and attributes the same way" do
      schema = Schema.extend(Schema.default(), nodes: [heading: [class: "title"]])
      before = Schema.node_spec(Schema.default(), :heading)
      after_ = Schema.node_spec(schema, :heading)

      assert after_.class == "title"
      assert after_.content == before.content
      assert after_.content_source == before.content_source
      assert after_.group == before.group
      assert after_.attrs == before.attrs
      assert after_.parse == before.parse
    end

    test "a key that is named is taken whole, so an override can also take away" do
      schema = Schema.extend(Schema.default(), marks: [bold: [parse: []]])

      assert Schema.mark_spec(schema, :bold).parse == []
    end

    test "a name that is new is built from its declaration alone" do
      schema = Schema.extend(Schema.default(), marks: [highlight: [class: "hl"]])

      assert Schema.mark_spec(schema, :highlight).render == nil
      assert Schema.mark_spec(schema, :highlight).parse == []
    end

    test "a redeclaration is still checked like any other declaration" do
      assert_raise ArgumentError, ~r/class of :bold must be a string/, fn ->
        Schema.extend(Schema.default(), marks: [bold: [class: :font_bold]])
      end
    end

    test "an addition still has to be consistent" do
      assert_raise ArgumentError, ~r/references :nowhere/, fn ->
        Schema.extend(Schema.default(), nodes: [callout: [content: "nowhere+", group: "block"]])
      end
    end

    test "the exported schema carries the addition, in order" do
      schema =
        Schema.extend(Schema.default(), nodes: [callout: [content: "block+", group: "block"]])

      assert List.last(Schema.to_json(schema)["nodes"]) == [
               "callout",
               %{"content" => "block+", "group" => "block"}
             ]
    end
  end
end
