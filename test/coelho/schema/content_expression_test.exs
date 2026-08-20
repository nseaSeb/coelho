defmodule Coelho.Schema.ContentExpressionTest do
  use ExUnit.Case, async: true

  alias Coelho.Schema.ContentExpression, as: Expr

  defp matches?(source, children) do
    {:ok, ast} = Expr.parse(source)
    Expr.matches?(ast, children, fn name, child -> name == child or name == :block end)
  end

  describe "parse/1" do
    test "parses names, sequences, choices and groups" do
      assert {:ok, {:name, :block}} = Expr.parse("block")
      assert {:ok, {:seq, [{:name, :paragraph}, {:name, :block}]}} = Expr.parse("paragraph block")
      assert {:ok, {:choice, [{:name, :text}, {:name, :image}]}} = Expr.parse("text | image")
      assert {:ok, {:repeat, {:choice, _}, 0, :infinity}} = Expr.parse("(text | image)*")
    end

    test "parses repetition operators" do
      assert {:ok, {:repeat, {:name, :block}, 1, :infinity}} = Expr.parse("block+")
      assert {:ok, {:repeat, {:name, :block}, 0, :infinity}} = Expr.parse("block*")
      assert {:ok, {:repeat, {:name, :block}, 0, 1}} = Expr.parse("block?")
      assert {:ok, {:repeat, {:name, :block}, 2, 2}} = Expr.parse("block{2}")
      assert {:ok, {:repeat, {:name, :block}, 2, :infinity}} = Expr.parse("block{2,}")
      assert {:ok, {:repeat, {:name, :block}, 1, 3}} = Expr.parse("block{1,3}")
    end

    test "parses the empty expression" do
      assert {:ok, :empty} = Expr.parse("")
    end

    test "reports malformed expressions" do
      assert {:error, _} = Expr.parse("(block")
      assert {:error, _} = Expr.parse("block)")
      assert {:error, _} = Expr.parse("block{2,1}")
      assert {:error, _} = Expr.parse("block{")
      assert {:error, _} = Expr.parse("|")
      assert {:error, _} = Expr.parse("block!")
    end
  end

  describe "matches?/3" do
    test "plus requires at least one" do
      refute matches?("paragraph+", [])
      assert matches?("paragraph+", [:paragraph])
      assert matches?("paragraph+", [:paragraph, :paragraph])
    end

    test "star accepts none" do
      assert matches?("paragraph*", [])
      assert matches?("paragraph*", [:paragraph])
    end

    test "sequence with a trailing mandatory item does not get eaten by the star" do
      # A greedy matcher fails this: the star would swallow both paragraphs
      # and leave nothing for the mandatory one.
      assert matches?("paragraph* paragraph", [:paragraph, :paragraph])
      refute matches?("paragraph* paragraph", [])
    end

    test "a group name matches any of its members" do
      assert matches?("paragraph block*", [:paragraph, :heading, :paragraph])
      refute matches?("paragraph block*", [:heading, :paragraph])
    end

    test "ranges are honoured" do
      refute matches?("paragraph{2,3}", [:paragraph])
      assert matches?("paragraph{2,3}", [:paragraph, :paragraph])
      assert matches?("paragraph{2,3}", [:paragraph, :paragraph, :paragraph])
      refute matches?("paragraph{2,3}", List.duplicate(:paragraph, 4))
    end

    test "alternation" do
      assert matches?("(text | image)*", [:text, :image, :text])
      refute matches?("(text | image)*", [:text, :heading])
    end
  end
end
