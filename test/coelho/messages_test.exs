defmodule Coelho.MessagesTest do
  use ExUnit.Case, async: true

  alias Coelho.Document.Error

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp paragraph(content), do: %{"type" => "paragraph", "content" => content}
  defp text(text, marks \\ [])
  defp text(text, []), do: %{"type" => "text", "text" => text}
  defp text(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp first_error(document) do
    {:error, [error | _rest]} = Coelho.validate(document)
    error
  end

  describe "describe/1" do
    test "counts positions from one, the way a person does" do
      error =
        first_error(doc([paragraph([text("ok")]), %{"type" => "script"}]))

      assert %{position: [2], scope: :node} = Error.describe(error)
    end

    test "names the attribute that failed, and the mark it sat on" do
      error =
        first_error(
          doc([
            paragraph([
              text("x", [%{"type" => "link", "attrs" => %{"href" => "javascript:alert(1)"}}])
            ])
          ])
        )

      assert %{
               position: [1, 1],
               scope: :attribute,
               attribute: "href",
               mark: 1,
               location: "content[0].content[0].marks[0].attrs.href"
             } = Error.describe(error)
    end

    test "names an attribute on the node itself, with no mark" do
      error =
        first_error(doc([%{"type" => "heading", "attrs" => %{"level" => 99}, "content" => []}]))

      assert %{scope: :attribute, attribute: "level", mark: nil, position: [1]} =
               Error.describe(error)
    end

    test "calls a mark a mark when the failure is the mark itself" do
      error = first_error(doc([paragraph([text("x", [%{"type" => "blink"}])])]))

      assert %{scope: :mark, mark: 1, attribute: nil} = Error.describe(error)
    end

    test "says the document when nothing narrower is to blame" do
      assert %{scope: :document, position: []} = Error.describe(first_error(nil))
    end

    test "carries the message through untouched, for a log to keep" do
      error = first_error(doc([%{"type" => "script"}]))

      assert Error.describe(error).message == error.message
      assert Error.describe(error).location == "content[0]"
    end
  end

  describe "humanize/1" do
    test "puts the position in words instead of in brackets" do
      error = first_error(doc([paragraph([text("ok")]), %{"type" => "script"}]))

      assert Error.humanize(error) == ~s(block 2: unknown node type "script")
    end

    test "names the attribute a reader would recognise" do
      error =
        first_error(
          doc([
            paragraph([
              text("x", [%{"type" => "link", "attrs" => %{"href" => "javascript:alert(1)"}}])
            ])
          ])
        )

      assert Error.humanize(error) ==
               ~s(block 1, item 1, "href": scheme "javascript" is not allowed)
    end

    test "says the document, and nothing about paths, at the root" do
      assert Error.humanize(first_error(nil)) == "the document: expected an object"
    end

    test "never mentions content[" do
      for document <- [
            nil,
            %{},
            doc([%{"type" => "script"}]),
            doc([paragraph([%{"type" => "text"}])])
          ] do
        assert %{message: _} = describe = Error.describe(first_error(document))
        refute Error.humanize(first_error(document)) =~ "content["
        assert is_list(describe.position)
      end
    end
  end
end
