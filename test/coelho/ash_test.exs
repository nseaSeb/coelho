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

  describe "atomic updates" do
    test "a document given as itself is cast the ordinary way" do
      # `{:ok, …}` and not `{:atomic, …}`, which is what Ash's own default
      # answers: the atomic branch puts the value into the changeset's
      # atomics, past the allow_nil? and required-attribute checks.
      assert {:ok, document} =
               Type.cast_atomic(doc([paragraph([text("hello")])]), constraints())

      assert Coelho.to_html(document, RichText.schema()) == "<p>hello</p>"
    end

    test "and Ash answers the same thing without going through us at all" do
      # Ash short-circuits a literal straight to cast_input unless the type
      # defines handle_change/3 or prepare_change/3, so the two paths have to
      # agree — otherwise adding handle_change/3 later changes what a cast
      # returns.
      document = doc([paragraph([text("hello")])])

      assert Ash.Type.cast_atomic(Type, document, constraints()) ==
               Type.cast_atomic(document, constraints())
    end

    test "nil stays nil, and stays on the checked path" do
      assert Type.cast_atomic(nil, constraints()) == {:ok, nil}
    end

    test "and one that fails validation is an error, not an atomic anything" do
      hostile = doc([%{"type" => "heading", "content" => [text("T")]}])

      assert {:error, error} = Type.cast_atomic(hostile, constraints())
      assert error[:validation] == :coelho
    end

    test "an expression is refused, with the reason spelled out" do
      # Validating a document means walking its tree in Elixir. No database
      # expression can do that, so this is not a gap to close later — the
      # message says why, because `require_atomic? true` refuses with it.
      ref = %Ash.Query.Ref{attribute: :body, relationship_path: []}

      assert {:not_atomic, reason} = Type.cast_atomic(ref, constraints())
      assert reason =~ "walking its tree in Elixir"
      assert reason =~ "require_atomic? false"
    end

    test "the reason is Coelho's own, not Ash's default" do
      # Ash's default says only that the type does not support it. Ours says
      # what to do instead, which is the difference between a shrug and an
      # answer.
      refute Coelho.Ash.Type.not_atomic_reason() =~ "does not support atomic updates"
    end
  end
end
