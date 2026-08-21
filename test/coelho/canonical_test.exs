defmodule Coelho.CanonicalTest do
  use ExUnit.Case, async: true

  alias Coelho.{Document, Schema}

  defp schema, do: Schema.default()

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp validate!(document) do
    {:ok, document} = Document.validate(document, schema())
    document
  end

  describe "mark order" do
    test "the same fragment normalises the same however the marks were added" do
      bold = %{"type" => "bold"}
      link = %{"type" => "link", "attrs" => %{"href" => "/a"}}

      one = validate!(doc([paragraph([text("x", [bold, link])])]))
      other = validate!(doc([paragraph([text("x", [link, bold])])]))

      assert one == other
      assert Document.hash(one) == Document.hash(other)
    end

    test "the order is the schema's, not the document's" do
      document =
        validate!(
          doc([
            paragraph([
              text("x", [%{"type" => "link", "attrs" => %{"href" => "/a"}}, %{"type" => "bold"}])
            ])
          ])
        )

      marks = document["content"] |> hd() |> Map.fetch!("content") |> hd() |> Map.fetch!("marks")

      assert Enum.map(marks, & &1["type"]) == ["bold", "link"]
    end

    test "and it is the order the marks render in" do
      document =
        validate!(
          doc([
            paragraph([
              text("x", [%{"type" => "link", "attrs" => %{"href" => "/a"}}, %{"type" => "bold"}])
            ])
          ])
        )

      assert Coelho.to_html(document) == ~s(<p><strong><a href="/a">x</a></strong></p>)
    end
  end

  describe "canonical/1" do
    test "does not depend on the order the keys happen to sit in" do
      one = %{"type" => "text", "text" => "x", "marks" => [%{"type" => "bold"}]}
      other = %{"marks" => [%{"type" => "bold"}], "text" => "x", "type" => "text"}

      assert Document.canonical(one) == Document.canonical(other)
    end

    test "escapes what would otherwise close the encoding" do
      document = validate!(doc([paragraph([text(~s(a "b" \\ c\n))])]))
      canonical = Document.canonical(document)

      assert canonical =~ ~S(\")
      assert canonical =~ ~S(\\)
      assert canonical =~ ~S(\n)
    end

    test "two documents differing only in their text differ" do
      one = validate!(doc([paragraph([text("a")])]))
      other = validate!(doc([paragraph([text("b")])]))

      refute Document.canonical(one) == Document.canonical(other)
    end
  end

  describe "hash/2" do
    test "is stable across a JSON round trip that reorders keys" do
      document = validate!(doc([paragraph([text("hello", [%{"type" => "bold"}])])]))
      reordered = document |> JSON.encode!() |> JSON.decode!()

      assert Document.hash(document) == Document.hash(reordered)
    end

    test "is nil for a document with nothing in it" do
      assert Document.hash(validate!(doc([paragraph([])]))) == nil
      assert Document.hash(%{"type" => "doc"}) == nil
      assert Document.hash(nil) == nil
    end

    test "answers a different digest for a different algorithm" do
      document = validate!(doc([paragraph([text("x")])]))

      assert String.length(Document.hash(document, :sha256)) == 64
      assert String.length(Document.hash(document, :sha512)) == 128
    end
  end

  describe "text_length/1" do
    test "counts what was typed, not what to_text/2 materialises" do
      document =
        validate!(
          doc([
            paragraph([text("one")]),
            %{
              "type" => "bullet_list",
              "content" => [
                %{
                  "type" => "list_item",
                  "content" => [paragraph([text("two")])]
                }
              ]
            }
          ])
        )

      assert Document.text_length(document) == 6
      assert String.length(Document.to_text(document, schema())) > 6
    end

    test "counts graphemes, so a combining sequence is one character" do
      assert Document.text_length(validate!(doc([paragraph([text("👨‍👩‍👧")])]))) == 1
    end

    test "is zero for a document holding no text" do
      assert Document.text_length(%{"type" => "doc"}) == 0
      assert Document.text_length(nil) == 0
    end
  end

  describe "schema versions" do
    defp versioned(version), do: Schema.extend(Schema.default(), version: version)

    test "a versioned schema stamps what it validates" do
      {:ok, document} = Document.validate(doc([paragraph([text("x")])]), versioned(2))

      assert document["schema_version"] == 2
    end

    test "and accepts a document already carrying its own version" do
      {:ok, document} = Document.validate(doc([paragraph([text("x")])]), versioned(2))
      {:ok, again} = Document.validate(document, versioned(2))

      assert again == document
    end

    test "a document from another version is refused, not guessed at" do
      {:ok, document} = Document.validate(doc([paragraph([text("x")])]), versioned(1))

      assert {:error, [error]} = Document.validate(document, versioned(2))
      assert error.message =~ "schema version 1"
      assert error.message =~ "Coelho.migrate/2"
    end

    test "an unversioned schema refuses a document that claims a version" do
      document = Map.put(doc([paragraph([text("x")])]), "schema_version", 1)

      assert {:error, [error]} = Document.validate(document, schema())
      assert error.message =~ "schema_version"
    end

    test "the stamp is part of the hash, so a migration changes it" do
      {:ok, one} = Document.validate(doc([paragraph([text("x")])]), versioned(1))
      {:ok, two} = Document.validate(doc([paragraph([text("x")])]), versioned(2))

      refute Document.hash(one) == Document.hash(two)
    end
  end

  describe "migrate/2" do
    test "runs the step and restamps" do
      {:ok, document} = Document.validate(doc([paragraph([text("x")])]), versioned(1))

      assert {:ok, migrated} =
               Coelho.migrate(document, from: 1, to: 2, with: &Map.put(&1, "content", []))

      assert migrated["schema_version"] == 2
      assert migrated["content"] == []
    end

    test "refuses a document that is not at the version claimed" do
      {:ok, document} = Document.validate(doc([paragraph([text("x")])]), versioned(2))

      assert {:error, message} = Coelho.migrate(document, from: 1, to: 2, with: & &1)
      assert message =~ "schema version 2"
    end

    test "crosses several versions with a map of steps" do
      document = %{"type" => "doc", "content" => [], "schema_version" => 1}
      step = fn suffix -> fn doc -> Map.update!(doc, "content", &(&1 ++ [suffix])) end end

      assert {:ok, migrated} =
               Coelho.migrate(document,
                 from: 1,
                 to: 3,
                 with: %{2 => step.("a"), 3 => step.("b")}
               )

      assert migrated["content"] == ["a", "b"]
      assert migrated["schema_version"] == 3
    end

    test "says so when a single step is asked to cross more than one version" do
      document = %{"type" => "doc", "content" => [], "schema_version" => 1}

      assert {:error, message} = Coelho.migrate(document, from: 1, to: 3, with: & &1)
      assert message =~ "more than one version"
    end

    test "refuses to go backwards, whichever shape :with takes" do
      document = %{"type" => "doc", "content" => [], "schema_version" => 3}

      assert {:error, message} = Coelho.migrate(document, from: 3, to: 2, with: & &1)
      assert message =~ "cannot migrate backwards"

      assert {:error, message} = Coelho.migrate(document, from: 3, to: 2, with: %{2 => & &1})
      assert message =~ "cannot migrate backwards"
    end

    test "a version that is not a version is a call written wrong" do
      document = %{"type" => "doc", "content" => [], "schema_version" => 1}

      assert_raise ArgumentError, ~r/:to must be a positive integer/, fn ->
        Coelho.migrate(document, from: 1, to: "2", with: & &1)
      end
    end

    test "says so when a step is missing" do
      document = %{"type" => "doc", "content" => [], "schema_version" => 1}

      assert {:error, message} = Coelho.migrate(document, from: 1, to: 3, with: %{2 => & &1})
      assert message =~ "version 3"
    end
  end
end
