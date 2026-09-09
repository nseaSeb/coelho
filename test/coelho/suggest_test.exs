defmodule Coelho.SuggestTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  defp form(value), do: to_form(%{"body" => value}, as: :post)

  defp render(assigns) do
    render_component(&Coelho.LiveView.coelho_editor/1, Map.put(assigns, :field, form(nil)[:body]))
  end

  describe "the :suggest attribute" do
    test "puts nothing on the element when there is nothing to watch for" do
      refute render(%{}) =~ "data-coelho-suggest"
    end

    test "carries the triggers as JSON, with the event to push them under" do
      html = render(%{suggest: [{"@", event: "mention"}]})

      assert html =~ ~s(data-coelho-suggest=)
      assert html =~ "&quot;trigger&quot;:&quot;@&quot;"
      assert html =~ "&quot;event&quot;:&quot;mention&quot;"
      assert html =~ "&quot;max&quot;:50"
    end

    test "keeps the order they were declared in, and their own bounds" do
      html = render(%{suggest: [{"@", event: "mention"}, {"/", event: "slash", max: 12}]})

      assert html =~ "&quot;max&quot;:12"
    end

    test "refuses a trigger that is not one character" do
      for trigger <- ["", "@@", "at"] do
        assert_raise ArgumentError, ~r/one character/, fn ->
          render(%{suggest: [{trigger, event: "mention"}]})
        end
      end
    end

    test "refuses a trigger with nothing to push it under" do
      # A trigger nothing watches for is a list that never opens, and it
      # would say so nowhere at all.
      assert_raise ArgumentError, ~r/needs an event/, fn ->
        render(%{suggest: [{"@", []}]})
      end

      assert_raise ArgumentError, ~r/needs an event/, fn ->
        render(%{suggest: [{"@", event: :mention}]})
      end
    end

    test "refuses a bound that is not a number of characters" do
      assert_raise ArgumentError, ~r/number of characters/, fn ->
        render(%{suggest: [{"@", event: "mention", max: 0}]})
      end
    end

    test "refuses two suggestions sharing a trigger" do
      # The editor looks for the character, not for the event behind it, so
      # the second of them could never be pushed.
      assert_raise ArgumentError, ~r/share the trigger/, fn ->
        render(%{suggest: [{"@", event: "mention"}, {"@", event: "emoji"}]})
      end
    end

    test "says what the shape is when it is given something else" do
      assert_raise ArgumentError, ~r/a trigger and its options/, fn ->
        render(%{suggest: ["@"]})
      end
    end
  end

  describe "insert_node/3 with :replace" do
    defp pushed(opts) do
      %Phoenix.LiveView.Socket{}
      |> Coelho.LiveView.insert_node(%{"type" => "mention"}, opts)
      |> Map.fetch!(:private)
      |> Map.fetch!(:live_temp)
      |> Map.fetch!(:push_events)
      |> List.last()
    end

    test "says nothing about a range when it was not asked to" do
      assert ["coelho:insert", %{replace: nil}] = pushed([])
    end

    test "names the query, so the editor takes the typing away with the node" do
      assert ["coelho:insert", %{replace: "query"}] = pushed(replace: :query)
    end

    test "finds the editor from the field or the name it was rendered for" do
      # The one thing every call site had to spell: the id is derived the way
      # `coelho_editor/1` derives it, in one place, from what the application
      # already has in hand.
      field = Phoenix.Component.to_form(%{"body" => nil}, as: :post)[:body]

      assert ["coelho:insert", %{id: "post_body-editor"}] = pushed(editor: field)
      assert ["coelho:insert", %{id: "page_intro_doc-editor"}] = pushed(editor: "page[intro_doc]")
      assert ["coelho:insert", %{id: "by-hand"}] = pushed(id: "by-hand", editor: field)
      assert ["coelho:insert", %{id: nil}] = pushed([])

      assert_raise ArgumentError, ~r/form field or the name/, fn -> pushed(editor: :body) end
    end

    test "refuses a range it has no way to find" do
      assert_raise ArgumentError, ~r/takes :query or nothing/, fn ->
        pushed(replace: :selection)
      end
    end
  end
end
