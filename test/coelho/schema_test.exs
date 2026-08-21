defmodule Coelho.SchemaTest do
  use ExUnit.Case, async: true

  alias Coelho.Schema

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

    test "redeclaring a name replaces it without a fork" do
      schema =
        Schema.extend(Schema.default(),
          nodes: [paragraph: [content: "inline*", group: "block", render: {"div", []}]]
        )

      assert length(schema.node_order) == length(Schema.default().node_order)
      assert Schema.node_spec(schema, :paragraph).render == {"div", []}
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
