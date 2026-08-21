defmodule Coelho.RenderAsTest do
  use ExUnit.Case, async: true

  alias Coelho.Schema

  # An attribute says how its value reaches the DOM, as data rather than as a
  # render function — so the server applies it, the exported schema carries
  # it to the browser, and an application changes it in one place.

  defp schema(render_as) do
    Schema.new(
      nodes: [
        doc: [content: "block+"],
        paragraph: [
          content: "inline*",
          group: "block",
          attrs: [
            align: [
              default: nil,
              validate: {:nullable, {:one_of, ~w(left center right justify)}},
              render_as: render_as
            ]
          ],
          render: {"p", []},
          parse: ["p"]
        ]
      ],
      marks: []
    )
  end

  defp document(attrs) do
    %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "attrs" => attrs,
          "content" => [%{"type" => "text", "text" => "x"}]
        }
      ]
    }
  end

  describe "the shipped default" do
    test "renders alignment as an inline style, as it always has" do
      assert Coelho.to_html(document(%{"align" => "center"})) ==
               ~s(<p style="text-align:center">x</p>)
    end

    test "and nothing at all when the attribute is unset" do
      assert Coelho.to_html(document(%{})) == "<p>x</p>"
    end
  end

  describe "{:class, map}" do
    test "renders the class the value maps to" do
      html =
        Coelho.to_html(
          document(%{"align" => "center"}),
          schema({:class, %{"center" => "text-center"}})
        )

      assert html == ~s(<p class="text-center">x</p>)
    end

    test "is its own allow list: a value it does not name renders nothing" do
      # Which is what makes it safe on a stored document. `Coelho.Ecto.Type`
      # does not re-validate on the way out, so a row written under a looser
      # schema reaches this renderer as it is.
      html =
        Coelho.to_html(
          document(%{"align" => "justify"}),
          schema({:class, %{"center" => "text-center"}})
        )

      assert html == "<p>x</p>"
    end

    test "joins the class the spec declares rather than replacing it" do
      schema =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [
              content: "inline*",
              group: "block",
              class: "prose-p",
              attrs: [
                align: [
                  default: nil,
                  validate: {:nullable, {:one_of, ~w(center)}},
                  render_as: {:class, %{"center" => "text-center"}}
                ]
              ],
              render: {"p", []},
              parse: ["p"]
            ]
          ]
        )

      assert Coelho.to_html(document(%{"align" => "center"}), schema) ==
               ~s(<p class="text-center prose-p">x</p>)
    end
  end

  describe "{:style, property}" do
    test "refuses an attribute with no closed list of values" do
      # A style attribute carries the value straight into markup that nothing
      # downstream bounds, and a stored document is not re-validated, so the
      # allow list is required when the schema is declared rather than hoped
      # for when it renders.
      assert_raise ArgumentError, ~r/needs a \{:one_of, list\} validator/, fn ->
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [
              content: "inline*",
              group: "block",
              attrs: [align: [default: nil, validate: :string, render_as: {:style, "text-align"}]],
              render: {"p", []}
            ]
          ]
        )
      end
    end

    test "checks the value against that list again at render time" do
      assert Coelho.to_html(document(%{"align" => "expression(alert(1))"})) == "<p>x</p>"
    end
  end

  describe "what the browser is handed" do
    test "carries the property and the values it may render" do
      json = Schema.to_json(Coelho.Schema.default())
      [_name, paragraph] = Enum.find(json["nodes"], fn [name, _spec] -> name == "paragraph" end)

      assert paragraph["attrRenderAs"] == %{
               "align" => %{
                 "style" => "text-align",
                 "values" => ~w(left center right justify)
               }
             }
    end

    test "carries the class map, and nothing at all for an attribute with no render_as" do
      json = Schema.to_json(schema({:class, %{"center" => "text-center"}}))
      [_name, paragraph] = Enum.find(json["nodes"], fn [name, _spec] -> name == "paragraph" end)

      assert paragraph["attrRenderAs"] == %{"align" => %{"class" => %{"center" => "text-center"}}}

      json = Schema.to_json(schema(nil))
      [_name, plain] = Enum.find(json["nodes"], fn [name, _spec] -> name == "paragraph" end)

      refute Map.has_key?(plain, "attrRenderAs")
    end

    test "leaves the attribute spec ProseMirror reads untouched" do
      # `attrRenderAs` travels beside `attrs` rather than inside it: what
      # goes into `attrs` is handed to ProseMirror as an attribute spec.
      json = Schema.to_json(Coelho.Schema.default())
      [_name, paragraph] = Enum.find(json["nodes"], fn [name, _spec] -> name == "paragraph" end)

      assert paragraph["attrs"] == %{"align" => %{"default" => nil}}
    end
  end

  describe "the shipped schema, asked for classes" do
    test "switches all three blocks that carry the attribute, in one line" do
      # `Schema.extend/2` replaces a node's declaration rather than
      # completing it, so redeclaring `paragraph` to change one attribute
      # means restating its content, group, render and parse — three times
      # over. Which is the friction this whole mechanism exists to remove.
      schema = Coelho.Schema.Default.build(align: {:class, %{"center" => "text-center"}})

      document = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "attrs" => %{"align" => "center"},
            "content" => [%{"type" => "text", "text" => "p"}]
          },
          %{
            "type" => "heading",
            "attrs" => %{"level" => 2, "align" => "center"},
            "content" => [%{"type" => "text", "text" => "h"}]
          },
          %{
            "type" => "bullet_list",
            "content" => [
              %{
                "type" => "list_item",
                "attrs" => %{"align" => "center"},
                "content" => [
                  %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "i"}]}
                ]
              }
            ]
          }
        ]
      }

      html = Coelho.to_html(document, schema)

      assert html =~ ~s(<p class="text-center">p</p>)
      assert html =~ ~s(<h2 class="text-center">h</h2>)
      assert html =~ ~s(<li class="text-center">)
      refute html =~ "text-align"
    end

    test "and the default is what it always was" do
      assert Coelho.Schema.Default.build() == Coelho.Schema.default()
    end
  end

  describe "reading back what it wrote" do
    test "a class map recognises its own class on import" do
      # A mechanism that renders a value but cannot recognise it again is
      # half a mechanism: the markup would lose the attribute on the next
      # import, and the editor on its own copy-paste.
      schema = Coelho.Schema.Default.build(align: {:class, %{"center" => "text-center"}})

      assert {:ok, document, _warnings} =
               Coelho.from_html(~s(<p class="text-center">x</p>), schema)

      assert [%{"attrs" => %{"align" => "center"}}] = document["content"]
      assert Coelho.to_html(document, schema) == ~s(<p class="text-center">x</p>)
    end

    test "a class it does not name is not its own" do
      schema = Coelho.Schema.Default.build(align: {:class, %{"center" => "text-center"}})

      assert {:ok, document, _warnings} = Coelho.from_html(~s(<p class="lead">x</p>), schema)
      refute Map.has_key?(hd(document["content"]), "attrs")
    end

    test "the rule's own extraction still wins where both answer" do
      # `align="right"` is a shape import tolerates that no `render_as`
      # emits, and the hand-written rule is what knows about it.
      assert {:ok, document, _warnings} =
               Coelho.from_html(~s(<p align="right" class="lead">x</p>))

      assert [%{"attrs" => %{"align" => "right"}}] = document["content"]
    end
  end

  describe "what a stored document cannot smuggle" do
    test "an attribute at its default renders, though it is not stored" do
      # `Coelho.Document` omits an attribute sitting at its schema default,
      # so reading the key and hoping would leave the server rendering
      # nothing where ProseMirror, which fills defaults in, renders it.
      schema =
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [
              content: "inline*",
              group: "block",
              attrs: [
                align: [
                  default: "center",
                  validate: {:one_of, ~w(left center right)},
                  render_as: {:style, "text-align"}
                ]
              ],
              render: {"p", []},
              parse: ["p"]
            ]
          ]
        )

      assert Coelho.to_html(document(%{}), schema) == ~s(<p style="text-align:center">x</p>)
    end

    test "a class map written with atom keys still matches a stored string" do
      # A document's attribute values come out of JSON and are never atoms,
      # so `%{center: …}` left alone would match nothing here while the
      # browser, which sees the exported JSON, matched it.
      html = Coelho.to_html(document(%{"align" => "center"}), schema({:class, %{center: "tc"}}))

      assert html == ~s(<p class="tc">x</p>)
    end

    test "a style whose allowed values are not strings is refused" do
      # The browser matches the JSON number and renders; the server would
      # render nothing. Neither half is wrong on its own, which is why this
      # is caught where the schema is written.
      assert_raise ArgumentError, ~r/values\s+are strings/, fn ->
        Schema.new(
          nodes: [
            doc: [content: "block+"],
            paragraph: [
              content: "inline*",
              group: "block",
              attrs: [
                weight: [
                  default: nil,
                  validate: {:nullable, {:one_of, [400, 700]}},
                  render_as: {:style, "font-weight"}
                ]
              ],
              render: {"p", []}
            ]
          ]
        )
      end
    end

    test "a value naming something every map inherits contributes nothing" do
      # `constructor` and `__proto__` are on every JavaScript object, so a
      # bare index would resolve them truthy — exactly the value written
      # under a looser schema the map is the allow list against.
      html =
        Coelho.to_html(
          document(%{"align" => "constructor"}),
          schema({:class, %{"center" => "text-center"}})
        )

      assert html == "<p>x</p>"
    end
  end

  describe "a heading, whose tag its level decides" do
    test "reaches the alignment its attribute declares, like any other block" do
      document = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "heading",
            "attrs" => %{"level" => 3, "align" => "right"},
            "content" => [%{"type" => "text", "text" => "x"}]
          }
        ]
      }

      assert Coelho.to_html(document) == ~s(<h3 style="text-align:right">x</h3>)
    end

    test "and a level no schema would accept still renders a heading" do
      # `Coelho.Ecto.Type` does not re-validate, and nothing downstream
      # escapes a tag name.
      document = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "heading",
            "attrs" => %{"level" => "1><script>alert(1)</script>"},
            "content" => [%{"type" => "text", "text" => "x"}]
          }
        ]
      }

      assert Coelho.to_html(document) == "<h1>x</h1>"
    end
  end
end
