defmodule Coelho.HTML do
  @moduledoc """
  Importing existing HTML into a document.

  This is the migration path. An application that already stores rich text as
  HTML — in a `:string` column, from another editor, from a feed — has to get
  that content into the schema before any of the rest of Coelho applies to
  it:

      {:ok, document, _warnings} = Coelho.HTML.from_html(post.body_html)

      post
      |> Ecto.Changeset.change(%{body: document})
      |> Repo.update()

  Requires [Floki](https://hex.pm/packages/floki), declared as an optional
  dependency: the parser is only needed on this path, and the document core
  has no dependencies at all.

  ## What the import does with markup it does not know

  Importing foreign HTML is not validation, and failing on the first
  surprise would make it useless. The rules are deliberate:

    * an element the schema has no rule for is **transparent** — it
      disappears and its children take its place, so a `<div>` wrapper or a
      `<span class="fancy">` does not cost you the text inside it
    * `<script>`, `<style>`, `<head>`, `<template>` and `<noscript>` are
      dropped **with their content**
    * an element whose attributes fail the schema's validators — an `<img>`
      with no `src`, an `<a href="javascript:…">` — is treated as unknown, so
      the link text survives while the link does not
    * inline content in a place that demands blocks is wrapped in the
      schema's first suitable block, which is how a bare `Hello` at the top
      level becomes a paragraph
    * whitespace is collapsed as HTML collapses it, and runs of whitespace
      between blocks are dropped

  What comes out is a validated, normalised document, or `{:error, errors}`
  if what remained still does not fit the schema.

  ## Teaching a schema to import

  Each node and mark declares the tags it comes from, in the same spirit as
  the `parseDOM` rules on the browser side:

      paragraph: [content: "inline*", group: "block", parse: ["p"]]

      heading: [
        content: "inline*",
        group: "block",
        parse: [{"h1", %{"level" => 1}}, {"h2", %{"level" => 2}}]
      ]

      link: [parse: [{"a", &Coelho.HTML.take(&1, ~w(href title))}]]

  A rule is a tag, optionally paired with the attributes to give the node: a
  fixed map, a function of the element's HTML attributes, or a function of
  those and the element's text. Rules are tried in declaration order, nodes
  before marks, and a rule whose attributes fail the schema does not match —
  which is how `<span data-user-id="7">` becomes a mention while every other
  span stays a span.
  """

  alias Coelho.Document
  alias Coelho.Schema
  alias Coelho.Schema.{Attr, ContentExpression, NodeSpec}

  @type rule :: {String.t(), map() | (map() -> map())}

  # Dropped with their content: none of it is text the reader ever saw.
  @discarded ~w(script style head template noscript)

  # Floki's default parser discards data nodes made only of whitespace, with
  # no option to keep them (floki_mochi_html.erl, `tree/3`). Between two
  # blocks that is what we want; between two inline elements it silently
  # welds words together — `<b>a</b> <i>b</i>` would import as "ab". So the
  # separator is carried through the parser as a character the parser has no
  # opinion about, and turned back into a space on the way out.
  @separator "\u{E000}"

  # And inside `<pre>`, where whitespace is content and replacing a run with
  # one character would flatten indentation, the run is *fenced* instead:
  # the parser keeps the node because it is no longer whitespace-only, and the
  # fence comes off with nothing lost.
  @fence "\u{E001}"

  @doc """
  Converts HTML into a validated document, and says what it left behind.

  The import is lenient by design: markup the schema has no rule for is
  dropped and the text inside it is kept, because the alternative — refusing
  the paste — loses more. But silence about it is its own problem. Someone
  importing terms and conditions out of a word processor gets a document
  back with the tables gone and no way to know, and finds out from a reader.

  So the third element of the result says what was removed:

      {:ok, document, warnings} = Coelho.HTML.from_html(html, schema)
      #=> warnings: [
      #=>   %{kind: :dropped_attribute, tag: "p", attribute: "style", count: 12},
      #=>   %{kind: :rejected_element, tag: "a", count: 1},
      #=>   %{kind: :unknown_element, tag: "table", count: 3}
      #=> ]

    * `:unknown_element` — no node or mark in the schema parses that tag; the
      element is gone and its text was lifted into its parent
    * `:rejected_element` — the schema has a rule for the tag, but the
      attributes the element carried failed their validators, so the rule did
      not apply. `<a href="javascript:alert(1)">` is this one: the text
      stays, the link does not
    * `:dropped_attribute` — the element was kept, and this attribute is not
      one its rule extracts

  Warnings are counts per tag, in a stable order, and they describe the
  *HTML*: an element the schema knows but that could not fit where it
  appeared — a list item outside a list — is repaired by the import rather
  than reported here. A mark refused because of where it sat, such as bold
  inside a code block, is not reported either.
  """
  @spec from_html(String.t(), Schema.t()) :: {:ok, map(), [warning()]} | {:error, term()}
  def from_html(html, %Schema{} = schema \\ Schema.default()) when is_binary(html) do
    with {:ok, trees} <- html |> mark_separators() |> parse_fragment(),
         {:ok, document} <- trees |> convert(schema, :all, []) |> finish(schema) do
      {:ok, document, warnings(trees, schema)}
    end
  end

  @type warning ::
          %{kind: :unknown_element | :rejected_element, tag: String.t(), count: pos_integer()}
          | %{
              kind: :dropped_attribute,
              tag: String.t(),
              attribute: String.t(),
              count: pos_integer()
            }

  # A second, read-only walk rather than an accumulator threaded through the
  # conversion: the conversion lifts, wraps and merges as it goes, and
  # carrying a warning list through all of it would put a reporting concern
  # inside every transform that has nothing to do with reporting.
  defp warnings(trees, schema) do
    trees
    |> collect_warnings(schema, [])
    |> Enum.frequencies()
    |> Enum.sort()
    |> Enum.map(fn
      {{:dropped_attribute, tag, attribute}, count} ->
        %{kind: :dropped_attribute, tag: tag, attribute: attribute, count: count}

      {{kind, tag}, count} ->
        %{kind: kind, tag: tag, count: count}
    end)
  end

  defp collect_warnings(trees, schema, acc) when is_list(trees),
    do: Enum.reduce(trees, acc, &collect_warnings(&1, schema, &2))

  defp collect_warnings({tag, attrs, children}, schema, acc) when is_binary(tag) do
    acc =
      case match(schema, tag, attrs, children) do
        nil ->
          if parses_tag?(schema, tag),
            do: [{:rejected_element, tag} | acc],
            else: [{:unknown_element, tag} | acc]

        matched ->
          dropped_attributes(schema, tag, attrs, children, matched, acc)
      end

    collect_warnings(children, schema, acc)
  end

  defp collect_warnings(_tree, _schema, acc), do: acc

  defp match(schema, tag, attrs, children) do
    match_node(schema, tag, attrs, children) || match_mark(schema, tag, attrs, children, :all)
  end

  # Told apart from an unknown element because the two call for different
  # answers: an unknown tag means the schema does not cover this markup, a
  # rejected one means it does, and refused what this element carried.
  defp parses_tag?(schema, tag) do
    specs = Map.values(schema.nodes) ++ Map.values(schema.marks)
    Enum.any?(specs, fn spec -> Enum.any?(spec.parse, &match?({^tag, _extract}, &1)) end)
  end

  # Whether an attribute was used cannot be read off the names that came out:
  # a rule is free to rename as it extracts, and the shipped ones do —
  # `style` becomes `align`, `data-user-id` becomes `user_id`. Comparing the
  # names either side reports every one of those as dropped, which on the
  # import path that motivated `align` means a warning per paragraph.
  #
  # So the question is asked of the rule instead: take the attribute away,
  # match again, and if nothing about the match changed then nothing read it.
  defp dropped_attributes(schema, tag, attrs, children, matched, acc) do
    Enum.reduce(attrs, acc, fn {name, _value}, acc ->
      without = Enum.reject(attrs, fn {other, _} -> other == name end)

      if match(schema, tag, without, children) == matched do
        [{:dropped_attribute, tag, name} | acc]
      else
        acc
      end
    end)
  end

  @doc """
  Keeps the named HTML attributes, dropping those the element does not carry.

  Handy inside a parse rule: `{"a", &Coelho.HTML.take(&1, ~w(href title))}`.
  """
  @spec take(%{optional(String.t()) => String.t()}, [String.t()]) :: map()
  def take(attrs, names), do: Map.take(attrs, names)

  defp mark_separators(html) do
    html
    |> String.replace([@separator, @fence], "")
    |> then(&Regex.split(~r{(<pre\b.*?</pre>)}is, &1, include_captures: true))
    |> Enum.map_join(fn part ->
      if String.starts_with?(String.downcase(part), "<pre") do
        # A code block that is only whitespace is a code block: the parser
        # would drop the node and it would come back empty, so the run is
        # fenced rather than replaced, keeping it to the character.
        Regex.replace(~r{>(\s+)<}u, part, ">" <> @fence <> "\\1" <> @fence <> "<")
      else
        # The `<` has to open a tag: a `>` and a `<` either side of whitespace
        # inside an attribute value are just characters.
        Regex.replace(~r{>(\s+)<(?=[a-zA-Z/!])}u, part, ">" <> @separator <> "<")
      end
    end)
  end

  # Floki is optional, so it is called through `apply/3`: a direct call would
  # warn at compile time in every application that does not use this path,
  # and the module still has to exist there to answer with a clear error.
  defp floki_text(trees), do: apply(Floki, :text, [trees])

  defp parse_fragment(html) do
    if Code.ensure_loaded?(Floki) do
      case apply(Floki, :parse_fragment, [html]) do
        {:ok, trees} -> {:ok, trees}
        {:error, reason} -> {:error, {:unparsable_html, reason}}
      end
    else
      {:error, :floki_not_available}
    end
  end

  # -- Conversion -----------------------------------------------------------

  defp convert(trees, schema, allowed_marks, marks) do
    trees
    |> Enum.flat_map(&convert_tree(&1, schema, allowed_marks, marks))
    |> merge_runs()
  end

  # Two ways a text node reaches storage holding whitespace that a fresh
  # import would collapse, and this closes both.
  #
  # An element the schema does not know is transparent, so
  # `a&nbsp;&nbsp;&nbsp;<i>&nbsp;&nbsp;&nbsp;b</i>` arrives as two nodes that
  # each kept one space, and storing them side by side stores two. And a
  # `<pre>` keeps its whitespace to the character — that is what a code block
  # is — but if the code block cannot sit where it landed, `fit/3` lifts its
  # text into the paragraph around it, and the run arrives verbatim in a
  # place where nothing keeps it.
  #
  # Either way the document is legal and renders correctly, and importing
  # what it rendered to collapses the run: a round trip through storage goes
  # on shortening people's text, a space at a time. So every text node is
  # collapsed here, whole — this only ever runs in an inline context, because
  # a node that takes its text verbatim never goes through `convert/4` at
  # all.
  #
  # Marks have to match to merge: the space between bold and plain text
  # belongs to one of them, and joining across the boundary would move it.
  defp merge_runs(children) do
    children
    |> Enum.reduce([], fn
      %{"type" => "text"} = node, [%{"type" => "text"} = previous | rest] = acc ->
        if Map.get(node, "marks", []) == Map.get(previous, "marks", []) do
          [%{previous | "text" => collapse(previous["text"] <> node["text"])} | rest]
        else
          [collapse_text(node) | acc]
        end

      %{"type" => "text"} = node, acc ->
        [collapse_text(node) | acc]

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
  end

  defp collapse_text(%{"text" => text} = node), do: %{node | "text" => collapse(text)}
  defp collapse_text(node), do: node

  defp convert_tree(text, _schema, _allowed_marks, marks) when is_binary(text) do
    case collapse(text) do
      "" -> []
      text -> [text_node(text, marks)]
    end
  end

  # Whitespace between two inline elements is a word separator and has to
  # survive; whitespace between two blocks is source indentation and does
  # not. Both arrive here as the same text node, so the distinction is made
  # later, once it is known what the run sits between.

  defp convert_tree({tag, attrs, children}, schema, allowed_marks, marks) do
    cond do
      tag in @discarded ->
        []

      node = match_node(schema, tag, attrs, children) ->
        build_node(node, children, schema, marks)

      mark = match_mark(schema, tag, attrs, children, allowed_marks) ->
        convert(children, schema, allowed_marks, add_mark(marks, mark))

      true ->
        # Transparent: an unknown element is not a reason to lose its content.
        convert(children, schema, allowed_marks, marks)
    end
  end

  defp convert_tree(_other, _schema, _allowed_marks, _marks), do: []

  # `<strong>a <b>b</b></strong>` is ordinary markup, and nesting a mark
  # inside itself would build a document the browser side could never produce
  # — marks are a set there — and markup that doubles on every round trip.
  defp add_mark(marks, mark) do
    if Enum.any?(marks, &(&1["type"] == mark["type"])), do: marks, else: marks ++ [mark]
  end

  # What a code block quotes, with two things taken out.
  #
  # A `<script>` or `<style>` is dropped with its content everywhere else, and
  # a raw-text element survives the parser's whitespace handling, so `Floki`'s
  # own text function would let exactly that content through here and nowhere
  # else. And the separator planted before parsing is invisible on the page
  # but is a real character: an unclosed `<pre>` escapes the region that is
  # spared, and it would end up stored.
  defp verbatim_text(trees) do
    trees
    |> Enum.map(fn
      text when is_binary(text) -> scrub(text)
      {tag, _attrs, _children} when tag in @discarded -> ""
      {_tag, _attrs, children} -> verbatim_text(children)
      _other -> ""
    end)
    |> IO.iodata_to_binary()
  end

  defp text_node(text, []), do: %{"type" => "text", "text" => text}
  defp text_node(text, marks), do: %{"type" => "text", "text" => text, "marks" => marks}

  defp build_node({%NodeSpec{} = spec, attrs}, children, schema, marks) do
    node = %{"type" => Atom.to_string(spec.name)}
    node = if attrs == %{}, do: node, else: Map.put(node, "attrs", attrs)

    cond do
      spec.content == nil ->
        # A leaf may still be inline, and inline nodes carry marks.
        [if(spec.inline and marks != [], do: Map.put(node, "marks", marks), else: node)]

      spec.marks == [] ->
        # A node that forbids marks — a code block — takes its text verbatim,
        # tags and all, rather than losing what it was quoting.
        text = children |> verbatim_text() |> String.trim_trailing("\n")
        content = if text == "", do: [], else: [%{"type" => "text", "text" => text}]
        [Map.put(node, "content", content)]

      true ->
        content =
          children
          |> convert(schema, spec.marks, if(spec.inline, do: marks, else: []))
          |> fit(spec, schema)
          |> merge_runs()
          |> trim_edges()

        [Map.put(node, "content", content)]
    end
  end

  defp match_node(schema, tag, attrs, children) do
    Enum.find_value(schema.node_order, fn name ->
      spec = Schema.node_spec(schema, name)

      with {:ok, node_attrs} <- apply_rules(spec.parse, spec.attrs, tag, attrs, children),
           do: {spec, node_attrs}
    end)
  end

  defp match_mark(schema, tag, attrs, children, allowed_marks) do
    Enum.find_value(schema.mark_order, fn name ->
      if mark_allowed?(allowed_marks, name) do
        mark_from(Schema.mark_spec(schema, name), name, tag, attrs, children)
      end
    end)
  end

  defp mark_from(spec, name, tag, attrs, children) do
    with {:ok, mark_attrs} <- apply_rules(spec.parse, spec.attrs, tag, attrs, children) do
      mark = %{"type" => Atom.to_string(name)}
      if mark_attrs == %{}, do: mark, else: Map.put(mark, "attrs", mark_attrs)
    end
  end

  defp mark_allowed?(:all, _name), do: true
  defp mark_allowed?(allowed, name), do: name in allowed

  # A rule matches only if the attributes it produces survive the schema's
  # own validators. That is what turns `<a href="javascript:…">` into an
  # unknown element — the text stays, the link does not.
  defp apply_rules(rules, specs, tag, html_attrs, children) do
    html_attrs = Map.new(html_attrs)

    Enum.find_value(rules, fn
      {^tag, extract} ->
        extracted = extract_attrs(extract, html_attrs, children)

        # What `:render_as` wrote, read back — a mechanism that renders a
        # value but cannot recognise it again is half a mechanism, and the
        # markup would lose the attribute on the next import. The rule's own
        # extraction wins where both answer: it is the one that knows the
        # shapes an import has to tolerate beyond what Coelho itself emits.
        specs
        |> resolve_attrs(Map.merge(render_as_attrs(specs, html_attrs), extracted))

      _rule ->
        nil
    end)
  end

  defp render_as_attrs(specs, html_attrs) do
    for {name, %Attr{render_as: render_as}} <- specs,
        render_as != nil,
        value = render_as_value(render_as, html_attrs),
        into: %{},
        do: {Atom.to_string(name), value}
  end

  # The class the element carries, looked up the other way round. A class
  # the map does not name is not this attribute's, and a class list is
  # whitespace separated.
  defp render_as_value({:class, classes}, html_attrs) do
    named = Map.new(classes, fn {value, class} -> {class, value} end)

    html_attrs
    |> Map.get("class", "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find_value(&Map.get(named, &1))
  end

  defp render_as_value({:style, property}, html_attrs) do
    pattern = ~r/(?:^|;)\s*#{Regex.escape(property)}\s*:\s*([^;]+)/i

    case Regex.run(pattern, Map.get(html_attrs, "style", "")) do
      [_match, value] -> value |> String.trim() |> String.downcase()
      nil -> nil
    end
  end

  # A rule that only sees attributes cannot keep what the element said. The
  # two-argument form is given the element's text as well, which is how a
  # mention imported from `<span data-user-id="7">Ada</span>` keeps "Ada"
  # instead of being re-rendered as "@7".
  defp extract_attrs(extract, html_attrs, children) do
    cond do
      is_function(extract, 2) -> extract.(html_attrs, floki_text(children))
      is_function(extract, 1) -> extract.(html_attrs)
      true -> extract
    end
  end

  defp resolve_attrs(specs, extracted) do
    Enum.reduce_while(specs, {:ok, %{}}, fn {name, %Attr{} = spec}, {:ok, acc} ->
      key = Atom.to_string(name)

      case Map.fetch(extracted, key) do
        {:ok, value} ->
          value = scrub(value)

          case Attr.validate(spec.validate, value) do
            :ok -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, _reason} when spec.required -> {:halt, nil}
            {:error, _reason} -> {:cont, {:ok, Map.put(acc, key, spec.default)}}
          end

        :error when spec.required ->
          {:halt, nil}

        :error ->
          {:cont, {:ok, Map.put(acc, key, spec.default)}}
      end
    end)
  end

  # Nothing carrying the separator may reach the document, attribute values
  # included: the regex that plants it works on raw HTML, and raw HTML is not
  # only made of tags.
  defp scrub(value) when is_binary(value) do
    value |> String.replace(@separator, " ") |> String.replace(@fence, "")
  end

  defp scrub(value), do: value

  # -- Fitting --------------------------------------------------------------

  # Real HTML puts inline content where a schema wants blocks, all the time.
  # Rather than reject it, wrap each run of inline children in the schema's
  # first suitable block — the same move that turns a bare `Hello` into a
  # paragraph.
  defp fit([], _spec, _schema), do: []

  defp fit(children, %NodeSpec{content: content} = spec, schema) do
    if matches?(content, children, schema) do
      children
    else
      children
      |> lift_inadmissible(spec, schema, 0)
      |> wrap_inline_runs(spec, schema)
      |> Enum.filter(&admissible?(&1, spec, schema))
    end
  end

  # A child the parent cannot hold — a `<pre>` inside a `<p>`, a heading
  # inside a heading — is unwrapped rather than deleted, the same way an
  # unknown element is transparent. Deleting it would take its text with it.
  @lift_passes 8

  defp lift_inadmissible(children, _spec, _schema, @lift_passes), do: children

  defp lift_inadmissible(children, spec, schema, pass) do
    lifted = Enum.flat_map(children, &lift_child(&1, spec, schema))

    if lifted == children do
      children
    else
      lift_inadmissible(lifted, spec, schema, pass + 1)
    end
  end

  defp wrap_inline_runs(children, spec, schema) do
    case default_block(spec, schema) do
      nil ->
        children

      block ->
        children
        |> Enum.chunk_by(&inline?(&1, schema))
        |> Enum.flat_map(fn
          [first | _] = run ->
            cond do
              not inline?(first, schema) ->
                run

              blank?(run) ->
                []

              # Through `merge_runs/1` like every other inline context, and
              # for both of its reasons: a run lifted out of a code block
              # arrives verbatim and has to be collapsed before it is stored,
              # and lifting can leave two same-mark text nodes side by side
              # that belong together.
              true ->
                [
                  %{
                    "type" => Atom.to_string(block),
                    "content" => run |> merge_runs() |> trim_edges()
                  }
                ]
            end
        end)
    end
  end

  # Only a text node can be blank. Reading `"text"` off any node made an
  # image or a line break look like whitespace, and dropped the run it was in.
  # Only a block with content of its own is unwrapped. An inline child is not
  # inadmissible so much as unwrapped-yet — wrapping it is the next step —
  # and a childless one would simply vanish.
  defp lift_child(child, spec, schema) do
    cond do
      admissible?(child, spec, schema) -> [child]
      inline?(child, schema) -> [child]
      Map.get(child, "content", []) == [] -> [child]
      true -> Map.get(child, "content")
    end
  end

  defp blank?(run) do
    Enum.all?(run, fn node ->
      Map.get(node, "type") == "text" and String.trim(Map.get(node, "text", "")) == ""
    end)
  end

  defp default_block(spec, schema) do
    Enum.find(schema.node_order, fn name ->
      candidate = Schema.node_spec(schema, name)

      not candidate.inline and admits?(spec, name, schema) and
        candidate.content != nil and matches?(candidate.content, [dummy_text()], schema)
    end)
  end

  defp dummy_text, do: %{"type" => "text", "text" => "x"}

  defp admissible?(child, spec, schema) do
    case type_of(child, schema) do
      nil -> false
      name -> admits?(spec, name, schema)
    end
  end

  defp admits?(%NodeSpec{content: nil}, _name, _schema), do: false

  defp admits?(%NodeSpec{content: content}, name, schema) do
    content
    |> ContentExpression.names()
    |> Enum.any?(&Schema.instance_of?(schema, &1, name))
  end

  defp matches?(nil, _children, _schema), do: false

  defp matches?(content, children, schema) do
    types = Enum.map(children, &type_of(&1, schema))

    not Enum.any?(types, &is_nil/1) and
      ContentExpression.matches?(content, types, &Schema.instance_of?(schema, &1, &2))
  end

  defp inline?(child, schema) do
    case type_of(child, schema) do
      nil -> false
      name -> Schema.node_spec(schema, name).inline
    end
  end

  defp type_of(child, schema) do
    case Schema.resolve_node_name(schema, Map.get(child, "type")) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  # HTML collapses runs of whitespace, and so does the import; a document that
  # kept the source's indentation would render it.
  defp collapse(text) do
    text
    |> String.replace(@separator, " ")
    |> String.replace(@fence, "")
    |> String.replace(~r/\s+/u, " ")
  end

  # A block does not begin or end with a space, whatever the source's
  # indentation suggested.
  defp trim_edges([]), do: []

  # Until it settles: trimming can empty the last child and drop it, and
  # whatever it was hiding is then the last child in its turn. Trimming once
  # leaves a document that trims further the next time it is imported, and a
  # round trip through storage would then keep changing it.
  defp trim_edges(children) do
    trimmed =
      children
      |> List.update_at(0, &trim_text(&1, :leading))
      |> List.update_at(-1, &trim_text(&1, :trailing))
      |> Enum.reject(&(Map.get(&1, "type") == "text" and Map.get(&1, "text") == ""))

    if trimmed == children, do: children, else: trim_edges(trimmed)
  end

  defp trim_text(%{"type" => "text", "text" => text} = node, :leading),
    do: %{node | "text" => String.trim_leading(text)}

  defp trim_text(%{"type" => "text", "text" => text} = node, :trailing),
    do: %{node | "text" => String.trim_trailing(text)}

  defp trim_text(node, _side), do: node

  # -- Finishing ------------------------------------------------------------

  defp finish(children, schema) do
    spec = Schema.node_spec(schema, schema.top_node)
    children = children |> fit(spec, schema) |> merge_runs()

    children =
      if children == [] and not matches?(spec.content, [], schema) do
        Map.get(Coelho.empty(schema), "content", [])
      else
        children
      end

    %{"type" => Atom.to_string(schema.top_node), "content" => children}
    |> Document.validate(schema)
  end
end
