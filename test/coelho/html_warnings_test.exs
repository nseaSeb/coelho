defmodule Coelho.HTMLWarningsTest do
  use ExUnit.Case, async: true

  alias Coelho.{HTML, Schema}

  defp warnings(html, schema \\ Schema.default()) do
    {:ok, _document, warnings} = HTML.from_html(html, schema)
    warnings
  end

  describe "from_html/2 warnings" do
    test "an element the schema has no rule for is reported, with a count" do
      html = "<table><tr><td>a</td></tr><tr><td>b</td></tr></table>"

      assert %{kind: :unknown_element, tag: "table", count: 1} in warnings(html)
      assert %{kind: :unknown_element, tag: "td", count: 2} in warnings(html)
    end

    test "an element the schema knows but refused is told apart from one it does not know" do
      html = ~s{<p><a href="javascript:alert(1)">x</a></p>}

      assert %{kind: :rejected_element, tag: "a", count: 1} in warnings(html)
      refute Enum.any?(warnings(html), &(&1.kind == :unknown_element))
    end

    test "an attribute the rule does not take is reported under the name the HTML used" do
      html = ~s(<p class="lead" id="intro">x</p>)

      assert %{kind: :dropped_attribute, tag: "p", attribute: "class", count: 1} in warnings(html)
      assert %{kind: :dropped_attribute, tag: "p", attribute: "id", count: 1} in warnings(html)
    end

    test "an attribute the rule does take is not reported" do
      html = ~s(<a href="/a">x</a>)

      refute Enum.any?(warnings(html), &(&1.kind == :dropped_attribute))
    end

    test "nor one the rule read under another name" do
      # `style` becomes `align`, so comparing the names either side of the
      # rule would report it dropped on every paragraph of an imported
      # document — which is the import this attribute exists for.
      assert warnings(~s(<p style="text-align:center">x</p>)) == []
      assert warnings(~s(<h2 align="right">x</h2>)) == []
    end

    test "but one the rule read nothing from still is" do
      assert %{kind: :dropped_attribute, tag: "p", attribute: "style", count: 1} in warnings(
               ~s(<p style="color:red">x</p>)
             )
    end

    test "clean markup warns about nothing" do
      assert warnings("<p>hello <strong>world</strong></p>") == []
    end

    test "the order is stable, so two runs compare" do
      html = "<div><table></table><span>x</span></div>"

      assert warnings(html) == warnings(html)
      assert warnings(html) == Enum.sort_by(warnings(html), &{&1.kind, &1.tag})
    end

    test "a narrowed schema reports what the narrowing took away" do
      portal = Schema.restrict(Schema.default(), nodes: [:paragraph], marks: [:bold])

      assert %{kind: :unknown_element, tag: "h1", count: 1} in warnings(
               "<h1>T</h1><p>x</p>",
               portal
             )
    end

    test "the document itself still comes back, with the text kept" do
      assert {:ok, document, _warnings} = HTML.from_html("<table><td>kept</td></table>")
      assert Coelho.to_text(document) == "kept"
    end
  end
end
