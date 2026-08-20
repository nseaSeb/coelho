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
      assert nodes["heading"]["attrs"] == %{"level" => %{"default" => 1}}
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
end
