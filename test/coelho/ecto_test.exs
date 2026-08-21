defmodule Coelho.EctoTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  defmodule RichText do
    @schema Coelho.Schema.new(
              nodes: [
                doc: [content: "line+"],
                line: [content: "inline*", group: "block", render: {"p", []}]
              ]
            )

    # Holding the schema in a module attribute is the documented pattern; it
    # only works because remote function captures survive as literals, which
    # is why the render specs are named functions and not closures.
    def schema, do: @schema
  end

  defmodule Post do
    use Ecto.Schema
    import Coelho.Ecto

    embedded_schema do
      field(:title, :string)
      rich_text(:body)
      rich_text(:summary, document_schema: RichText.schema())
    end
  end

  defp changeset(params), do: cast(%Post{}, params, [:title, :body, :summary])

  defp doc(content), do: %{"type" => "doc", "content" => content}

  defp paragraph(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}

  describe "casting" do
    test "accepts a document map and normalises it" do
      changeset =
        changeset(%{
          body: doc([%{"type" => "heading", "attrs" => %{"level" => 3}, "content" => []}])
        })

      assert changeset.valid?
      assert %{"content" => [%{"attrs" => %{"level" => 3}}]} = get_change(changeset, :body)
    end

    test "accepts the JSON string a form posts back" do
      json = JSON.encode!(doc([paragraph("hello")]))

      changeset = changeset(%{body: json})

      assert changeset.valid?
      assert get_change(changeset, :body) == doc([paragraph("hello")])
    end

    test "casts nil and the empty string to nil" do
      assert changeset(%{body: nil}) |> get_field(:body) == nil
      assert changeset(%{body: ""}) |> get_field(:body) == nil
    end

    test "an invalid document makes the changeset invalid and says why" do
      changeset = changeset(%{body: doc([%{"type" => "script"}])})

      refute changeset.valid?

      assert {"is invalid rich text", opts} = changeset.errors[:body]
      assert opts[:validation] == :coelho
      assert opts[:errors] == ["content[0]: unknown node type \"script\""]
    end

    test "rejects a string that is not JSON" do
      changeset = changeset(%{body: "<p>hello</p>"})

      refute changeset.valid?
      assert {"is not valid JSON", _} = changeset.errors[:body]
    end

    test "rejects JSON that is not an object" do
      changeset = changeset(%{body: "[1, 2]"})

      refute changeset.valid?
      assert {"is not a rich text document", _} = changeset.errors[:body]
    end

    test "a field validates against its own schema" do
      # `line` exists in RichText but not in the default schema, and the
      # other way round for `paragraph`.
      assert changeset(%{summary: doc([%{"type" => "line", "content" => []}])}).valid?
      refute changeset(%{summary: doc([paragraph("x")])}).valid?
      refute changeset(%{body: doc([%{"type" => "line", "content" => []}])}).valid?
    end
  end

  describe "init/1" do
    test "refuses anything but a schema struct" do
      assert_raise ArgumentError, ~r/expects :document_schema to be a %Coelho.Schema\{\}/, fn ->
        Coelho.Ecto.Type.init(document_schema: :default)
      end
    end
  end

  describe "load and dump" do
    test "stored documents are not re-validated on the way out" do
      params = Coelho.Ecto.Type.init([])
      stored = doc([%{"type" => "node_from_a_future_schema"}])

      assert {:ok, ^stored} = Coelho.Ecto.Type.load(stored, nil, params)
      assert {:ok, ^stored} = Coelho.Ecto.Type.dump(stored, nil, params)
      assert {:ok, nil} = Coelho.Ecto.Type.load(nil, nil, params)
    end

    test "refuses a value that is not a document" do
      params = Coelho.Ecto.Type.init([])

      assert :error = Coelho.Ecto.Type.load("not a map", nil, params)
      assert :error = Coelho.Ecto.Type.dump("not a map", nil, params)
    end
  end
end
