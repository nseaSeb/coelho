defmodule Coelho.TestHelpersTest do
  use ExUnit.Case, async: true

  alias Coelho.LiveViewTest

  defp paragraph(text) do
    %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}
      ]
    }
  end

  defp rendered(name, document) do
    ~s(<form><input type="hidden" name="#{name}" id="x" value="#{escape(JSON.encode!(document))}"></form>)
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  describe "document/2" do
    test "reads what the editor is holding, out of the hidden input" do
      html = rendered("page[intro_doc]", paragraph("bonjour"))

      assert LiveViewTest.document(html, "page[intro_doc]") == paragraph("bonjour")
    end

    test "puts back every character Phoenix escaped" do
      html = rendered("a[b]", paragraph(~s(a & b < c > d " e ' f)))

      assert LiveViewTest.document(html, "a[b]") == paragraph(~s(a & b < c > d " e ' f))
    end

    test "hands back the raw string when the input does not hold a document" do
      html = ~s(<input type="hidden" name="a[b]" value="not json">)

      assert LiveViewTest.document(html, "a[b]") == "not json"
    end

    test "answers nil when there is no such input" do
      assert LiveViewTest.document("<form></form>", "a[b]") == nil
    end

    test "does not confuse one editor's input for another's" do
      html =
        rendered("page[intro_doc]", paragraph("intro")) <>
          rendered("page[news_doc]", paragraph("news"))

      assert LiveViewTest.document(html, "page[news_doc]") == paragraph("news")
    end
  end

  describe "params/3" do
    # The nesting is what a browser posts and what Plug.Conn.Query reads back;
    # getting it wrong shows up as "the form ignored the change", which says
    # nothing about why.
    test "nests a bracketed name the way a form does" do
      json = JSON.encode!(paragraph("x"))

      assert LiveViewTest.params("page[intro_doc]", paragraph("x")) ==
               %{"page" => %{"intro_doc" => json}}

      assert LiveViewTest.params("body", paragraph("x")) == %{"body" => json}
      assert LiveViewTest.params("a[b][c]", paragraph("x")) == %{"a" => %{"b" => %{"c" => json}}}
    end

    test "merges what the change has to arrive with, without flattening it" do
      params =
        LiveViewTest.params("page[intro_doc]", paragraph("x"), %{"page" => %{"title" => "Été"}})

      assert %{"page" => %{"title" => "Été", "intro_doc" => _json}} = params
    end

    test "takes the name off a form field too" do
      field = %Phoenix.HTML.FormField{
        id: "post_body",
        name: "post[body]",
        errors: [],
        field: :body,
        form: nil,
        value: nil
      }

      assert %{"post" => %{"body" => _json}} = LiveViewTest.params(field, paragraph("x"))
    end

    test "refuses a name that is not one" do
      assert_raise ArgumentError, ~r/is not an input name/, fn ->
        LiveViewTest.params("[]", paragraph("x"))
      end
    end
  end
end
