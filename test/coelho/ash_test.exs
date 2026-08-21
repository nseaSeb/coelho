defmodule Coelho.AshTest do
  use ExUnit.Case, async: true

  alias Coelho.Test.{Post, RichText}
  alias Coelho.Test.RichTextType, as: Type

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp constraints, do: [document_schema: RichText.schema()]

  describe "the type itself" do
    test "stores in a map column" do
      assert Type.storage_type([]) == :map
    end

    test "declares the schema as a constraint, and it is required" do
      assert Keyword.fetch!(Type.constraints(), :document_schema)[:required]
    end

    test "casts a document map, and normalises it" do
      spelled = doc([%{"type" => "paragraph", "attrs" => %{"align" => nil}, "content" => []}])

      assert {:ok, document} = Type.cast_input(spelled, constraints())
      refute Map.has_key?(hd(document["content"]), "attrs")
    end

    test "casts the JSON string a form posts back" do
      json = JSON.encode!(doc([paragraph([text("hello")])]))

      assert {:ok, document} = Type.cast_input(json, constraints())
      assert Coelho.to_html(document, RichText.schema()) == "<p>hello</p>"
    end

    test "casts nil and the empty string to nil" do
      assert Type.cast_input(nil, constraints()) == {:ok, nil}
      assert Type.cast_input("", constraints()) == {:ok, nil}
    end

    test "answers a string that is not JSON without raising" do
      assert {:error, message: "is not valid JSON"} = Type.cast_input("{oops", constraints())
    end

    test "an invalid document carries the path in the tree" do
      hostile =
        doc([
          paragraph([text("x", [%{"type" => "link", "attrs" => %{"href" => "javascript:x"}}])])
        ])

      assert {:error, error} = Type.cast_input(hostile, constraints())
      assert error[:location] == "content[0].content[0].marks[0].attrs.href"
      assert error[:reason] =~ "javascript"
      assert error[:validation] == :coelho
      assert [_ | _] = error[:errors]
    end

    test "a failure at the root says so rather than naming an empty path" do
      assert {:error, error} = Type.cast_input(%{"type" => "script"}, constraints())
      assert error[:location] == "document"
    end

    test "sanitize? repairs instead of rejecting" do
      hostile = doc([%{"type" => "heading", "content" => [text("T")]}, paragraph([text("kept")])])

      assert {:ok, document} =
               Type.cast_input(hostile, constraints() ++ [sanitize?: true])

      assert Coelho.to_html(document, RichText.schema()) == "<p>kept</p>"
    end

    test "reads a stored value back without re-validating it" do
      stored = %{"type" => "doc", "content" => [%{"type" => "heading"}]}

      assert Type.cast_stored(stored, constraints()) == {:ok, stored}
      assert Type.cast_stored(nil, constraints()) == {:ok, nil}
    end

    test "writes a document to the column, and refuses anything else" do
      assert Type.dump_to_native(%{"type" => "doc"}, constraints()) == {:ok, %{"type" => "doc"}}
      assert Type.dump_to_native(nil, constraints()) == {:ok, nil}
      assert Type.dump_to_native("not a document", constraints()) == :error
    end

    test "an attribute without the constraint says what is missing" do
      assert_raise ArgumentError, ~r/:document_schema constraint/, fn ->
        Type.cast_input(%{"type" => "doc"}, [])
      end
    end
  end

  describe "through a resource" do
    test "a valid document makes a valid changeset" do
      changeset =
        Ash.Changeset.for_create(Post, :create, %{body: doc([paragraph([text("hello")])])})

      assert changeset.valid?

      assert %{"content" => [%{"type" => "paragraph"}]} =
               Ash.Changeset.get_attribute(changeset, :body)
    end

    test "an invalid document surfaces as an InvalidAttribute on the field" do
      hostile = doc([%{"type" => "heading", "content" => [text("T")]}])

      changeset = Ash.Changeset.for_create(Post, :create, %{body: hostile})

      refute changeset.valid?

      assert [%Ash.Error.Changes.InvalidAttribute{field: :body} = error] = changeset.errors
      assert error.vars[:location] == "content[0]"
      assert error.vars[:reason] =~ "unknown node type"
    end

    test "the message renders the path it was given" do
      changeset = Ash.Changeset.for_create(Post, :create, %{body: %{"type" => "script"}})

      refute changeset.valid?
      assert [error] = changeset.errors
      assert Exception.message(error) =~ "document"
    end
  end
end
