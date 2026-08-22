defmodule Coelho.Schema.ContentExpressionTest do
  use ExUnit.Case, async: true

  alias Coelho.Schema.ContentExpression, as: Expr

  defp matches?(source, children) do
    {:ok, ast} = Expr.parse(source)
    Expr.matches?(ast, children, fn name, child -> name == child or name == :block end)
  end

  describe "how long it takes" do
    @tag timeout: 20_000
    test "grows with the number of children, not with its square" do
      # The document's own `"block+"` over its own children is the shape that
      # matters, and stepping the whole reachable set on every pass made the
      # work the square of the child count: 9 990 siblings — inside every
      # bound the shipped schema declares — took 8.6 seconds to accept, and
      # again on every render that sanitises. Stepping only what was reached
      # since the last pass makes it linear.
      #
      # Asserted as a ratio rather than as a duration: a machine's speed is
      # not the property under test. Four times the children costs about four
      # times the time when the work is linear, and about sixteen when it is
      # the square — so the line is drawn halfway between, where no amount of
      # a busy machine puts a linear run.
      small = elapsed(2_000)
      large = elapsed(8_000)

      ratio = large / max(small, 1)

      assert ratio < 8,
             "4x the children cost #{Float.round(ratio, 1)}x the time " <>
               "(#{small}µs then #{large}µs), which is the square creeping back"
    end

    defp elapsed(count) do
      {:ok, ast} = Expr.parse("block+")
      children = List.duplicate(:paragraph, count)

      # The best of three: what is being measured is the shape of the work,
      # and the fastest run is the one least polluted by everything else the
      # machine was doing — which on a busy CI box is most of it.
      1..3
      |> Enum.map(fn _ ->
        {micro, true} =
          :timer.tc(fn ->
            Expr.matches?(ast, children, fn name, child -> name == child or name == :block end)
          end)

        micro
      end)
      |> Enum.min()
    end
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
