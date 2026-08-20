defmodule CoelhoTest do
  use ExUnit.Case, async: true

  doctest Coelho

  test "empty/1 builds a document the schema accepts" do
    assert {:ok, _} = Coelho.validate(Coelho.empty())
  end

  test "empty/1 derives its child from the schema rather than assuming a paragraph" do
    schema =
      Coelho.Schema.new(
        nodes: [
          doc: [content: "line+"],
          line: [content: "inline*", group: "block"]
        ]
      )

    document = Coelho.empty(schema)

    assert document == %{"type" => "doc", "content" => [%{"type" => "line"}]}
    assert {:ok, _} = Coelho.validate(document, schema)
  end

  test "empty/1 leaves the document childless when the schema allows it" do
    schema =
      Coelho.Schema.new(nodes: [doc: [content: "block*"], p: [content: "text*", group: "block"]])

    assert Coelho.empty(schema) == %{"type" => "doc"}
    assert {:ok, _} = Coelho.validate(Coelho.empty(schema), schema)
  end

  test "empty/1 skips a candidate whose attributes are required" do
    schema =
      Coelho.Schema.new(
        nodes: [
          doc: [content: "block+"],
          mention: [
            group: "block",
            void: true,
            attrs: [user_id: [required: true, validate: :integer]]
          ],
          paragraph: [content: "inline*", group: "block"]
        ]
      )

    document = Coelho.empty(schema)

    assert document == %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
    assert {:ok, _} = Coelho.validate(document, schema)
  end

  test "to_html/2 accepts render options in place of the schema" do
    document = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "x"}]}
      ]
    }

    assert Coelho.to_html(document, nodes: %{paragraph: {"div", []}}) == "<div>x</div>"
    assert Coelho.to_html(document) == "<p>x</p>"
  end
end
