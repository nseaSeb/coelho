defmodule Coelho.Schema.ContentExpression do
  @moduledoc """
  Parser and matcher for ProseMirror-style content expressions.

  A content expression describes the sequence of children a node may hold,
  for example `"block+"`, `"paragraph block*"`, `"(text | image)*"` or
  `"heading{1,3}"`. Names refer either to a node name or to a group name.

  Matching is done by simulating the expression over the child list with a
  set of reachable positions, which handles alternation and repetition
  without building an explicit automaton. The child list of a rich text node
  is short, so the position-set simulation is cheap and, unlike a greedy
  matcher, it never backtracks incorrectly on expressions such as
  `"paragraph* paragraph"`.
  """

  @type ast ::
          :empty
          | {:name, atom()}
          | {:seq, [ast()]}
          | {:choice, [ast()]}
          | {:repeat, ast(), non_neg_integer(), non_neg_integer() | :infinity}

  @doc """
  Parses a content expression into an AST.

  Names become atoms, so this must only ever see developer-authored
  expressions — the same trust level as the schema declaration it comes
  from. Untrusted input goes through `Coelho.Schema.resolve_node_name/2`,
  which resolves against the schema instead of creating atoms.
  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- tokenize(source, []),
         {:ok, ast, []} <- parse_choice(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, [token | _]} -> {:error, "unexpected #{describe(token)}"}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Returns every name referenced by an expression, node or group alike.
  """
  @spec names(ast()) :: [atom()]
  def names(ast), do: ast |> collect_names() |> Enum.uniq()

  defp collect_names(:empty), do: []
  defp collect_names({:name, name}), do: [name]
  defp collect_names({:seq, list}), do: Enum.flat_map(list, &collect_names/1)
  defp collect_names({:choice, list}), do: Enum.flat_map(list, &collect_names/1)
  defp collect_names({:repeat, ast, _min, _max}), do: collect_names(ast)

  @doc """
  Checks whether `children` satisfies the expression.

  `match_fun` receives a name from the expression and a child, and answers
  whether that child is an instance of that name (directly, or through a
  group it belongs to).
  """
  @spec matches?(ast(), [term()], (atom(), term() -> boolean())) :: boolean()
  def matches?(ast, children, match_fun) when is_list(children) do
    length = length(children)
    array = List.to_tuple(children)
    reachable = step(ast, MapSet.new([0]), array, length, match_fun)
    MapSet.member?(reachable, length)
  end

  defp step(:empty, positions, _array, _length, _fun), do: positions

  defp step({:name, name}, positions, array, length, fun) do
    for position <- positions,
        position < length,
        fun.(name, elem(array, position)),
        into: MapSet.new(),
        do: position + 1
  end

  defp step({:seq, list}, positions, array, length, fun) do
    Enum.reduce(list, positions, &step(&1, &2, array, length, fun))
  end

  defp step({:choice, list}, positions, array, length, fun) do
    Enum.reduce(list, MapSet.new(), fn ast, acc ->
      MapSet.union(acc, step(ast, positions, array, length, fun))
    end)
  end

  defp step({:repeat, ast, min, max}, positions, array, length, fun) do
    positions =
      Enum.reduce(1..min//1, positions, fn _, acc -> step(ast, acc, array, length, fun) end)

    case max do
      :infinity -> repeat_until_stable(ast, positions, array, length, fun, :infinity)
      max -> repeat_until_stable(ast, positions, array, length, fun, max - min)
    end
  end

  # Each extra iteration is optional, so the reachable set only grows. It is
  # bounded by the number of children, hence the fixpoint always terminates.
  defp repeat_until_stable(_ast, positions, _array, _length, _fun, 0), do: positions

  defp repeat_until_stable(ast, positions, array, length, fun, remaining) do
    grown = MapSet.union(positions, step(ast, positions, array, length, fun))

    if MapSet.equal?(grown, positions) do
      positions
    else
      remaining = if remaining == :infinity, do: :infinity, else: remaining - 1
      repeat_until_stable(ast, grown, array, length, fun, remaining)
    end
  end

  # -- Tokenizer ------------------------------------------------------------

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in ~c" \t\n\r",
    do: tokenize(rest, acc)

  defp tokenize(<<"|", rest::binary>>, acc), do: tokenize(rest, [:pipe | acc])
  defp tokenize(<<"(", rest::binary>>, acc), do: tokenize(rest, [:open | acc])
  defp tokenize(<<")", rest::binary>>, acc), do: tokenize(rest, [:close | acc])
  defp tokenize(<<"*", rest::binary>>, acc), do: tokenize(rest, [{:repeat, 0, :infinity} | acc])
  defp tokenize(<<"+", rest::binary>>, acc), do: tokenize(rest, [{:repeat, 1, :infinity} | acc])
  defp tokenize(<<"?", rest::binary>>, acc), do: tokenize(rest, [{:repeat, 0, 1} | acc])

  defp tokenize(<<"{", rest::binary>>, acc) do
    case String.split(rest, "}", parts: 2) do
      [body, rest] -> with {:ok, token} <- parse_range(body), do: tokenize(rest, [token | acc])
      [_] -> {:error, "unterminated range, missing `}`"}
    end
  end

  defp tokenize(<<c, _::binary>> = source, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {name, rest} = take_name(source, "")
    tokenize(rest, [{:name, String.to_atom(name)} | acc])
  end

  defp tokenize(<<c::utf8, _::binary>>, _acc) do
    {:error, "unexpected character #{inspect(<<c::utf8>>)}"}
  end

  defp take_name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c == ?- do
    take_name(rest, <<acc::binary, c>>)
  end

  defp take_name(rest, acc), do: {acc, rest}

  defp parse_range(body) do
    case body |> String.trim() |> String.split(",") do
      [min] ->
        with {:ok, min} <- parse_integer(min), do: {:ok, {:repeat, min, min}}

      [min, ""] ->
        with {:ok, min} <- parse_integer(min), do: {:ok, {:repeat, min, :infinity}}

      [min, max] ->
        with {:ok, min} <- parse_integer(min),
             {:ok, max} <- parse_integer(max) do
          if max < min do
            {:error, "range maximum #{max} is below its minimum #{min}"}
          else
            {:ok, {:repeat, min, max}}
          end
        end

      _ ->
        {:error, "malformed range #{inspect(body)}"}
    end
  end

  defp parse_integer(source) do
    case Integer.parse(String.trim(source)) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, "malformed range bound #{inspect(source)}"}
    end
  end

  # -- Parser ---------------------------------------------------------------

  defp parse_choice(tokens) do
    with {:ok, first, rest} <- parse_seq(tokens) do
      case {first, rest} do
        {:empty, [:pipe | _]} -> {:error, "empty alternative around `|`"}
        _ -> collect_choice(rest, [first])
      end
    end
  end

  defp collect_choice([:pipe | rest], acc) do
    case parse_seq(rest) do
      {:ok, :empty, _rest} -> {:error, "empty alternative around `|`"}
      {:ok, ast, rest} -> collect_choice(rest, [ast | acc])
      {:error, message} -> {:error, message}
    end
  end

  defp collect_choice(rest, [single]), do: {:ok, single, rest}
  defp collect_choice(rest, acc), do: {:ok, {:choice, Enum.reverse(acc)}, rest}

  defp parse_seq(tokens), do: collect_seq(tokens, [])

  defp collect_seq([:open | _] = tokens, acc), do: collect_seq_item(tokens, acc)
  defp collect_seq([{:name, _} | _] = tokens, acc), do: collect_seq_item(tokens, acc)

  defp collect_seq(rest, []), do: {:ok, :empty, rest}
  defp collect_seq(rest, [single]), do: {:ok, single, rest}
  defp collect_seq(rest, acc), do: {:ok, {:seq, Enum.reverse(acc)}, rest}

  defp collect_seq_item(tokens, acc) do
    with {:ok, ast, rest} <- parse_postfix(tokens), do: collect_seq(rest, [ast | acc])
  end

  defp parse_postfix(tokens) do
    with {:ok, ast, rest} <- parse_atom(tokens), do: apply_postfix(ast, rest)
  end

  defp apply_postfix(ast, [{:repeat, min, max} | rest]),
    do: apply_postfix({:repeat, ast, min, max}, rest)

  defp apply_postfix(ast, rest), do: {:ok, ast, rest}

  defp parse_atom([{:name, name} | rest]), do: {:ok, {:name, name}, rest}

  defp parse_atom([:open | rest]) do
    case parse_choice(rest) do
      {:ok, ast, [:close | rest]} -> {:ok, ast, rest}
      {:ok, _ast, _rest} -> {:error, "unterminated group, missing `)`"}
      {:error, message} -> {:error, message}
    end
  end

  # No clause for an empty list: an atom is only ever parsed when `collect_seq`
  # has already seen a name or an opening parenthesis at the head.
  defp parse_atom([token | _]), do: {:error, "unexpected #{describe(token)}"}

  defp describe(:pipe), do: "`|`"
  defp describe(:open), do: "`(`"
  defp describe(:close), do: "`)`"
  defp describe({:name, name}), do: "name #{inspect(name)}"
  defp describe({:repeat, _min, _max}), do: "repetition operator"
end
