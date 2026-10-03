defmodule Coelho.Markdown do
  @moduledoc """
  Documents to Markdown, and back.

      Coelho.Markdown.to_markdown(document)
      #=> "## Release notes\\n\\nFixed **three** bugs."

  For a README, an export, a commit message, a language model's prompt —
  anywhere Markdown is the format and HTML is not. The output is CommonMark
  with two GitHub extensions, `~~strikethrough~~` and pipe tables, and every
  character a writer typed comes back as that character: what would be
  syntax is escaped, so a paragraph that starts with `#` stays a paragraph.

  A mark is written with its Markdown delimiters — `**`, `*`, `~~` — where
  CommonMark is certain to read them as such, and as the equivalent HTML
  element where it would not: a bold `*b` right after a letter, a span that
  begins with a space. Both are Markdown, and both come back.

  ## What Markdown cannot say

  It is dropped, or written another way, rather than approximated:

    * an empty paragraph or heading, and a line break at the edge of one
    * a paragraph's alignment, and a table cell's span; a table's first row
      is its header, whatever it held, and a cell is one line: its blocks run
      together, a line break in it is `<br>`, a `|` in it is `&#124;` and its
      code is `<code>`, since GitHub splits the row on every other `|`
    * a heading holding a line break is written as Coelho's own HTML for it
    * an attachment is a link to it — resolved through `:context`, as
      `Coelho.Render` resolves it — or its name when it has no URL, and its
      caption a paragraph after it
    * an image without alt text comes back with an empty one, and a URL comes
      back percent-encoded where CommonMark encodes it (`[`, `]`, a space)
    * a code block's language is written, and lost again on import, as it is
      by `Coelho.HTML.from_html/3`

  `from_markdown/3` goes the other way, through `Coelho.HTML.from_html/3`, so
  the schema decides what is kept exactly as it does for imported HTML. It
  needs the optional `:mdex` (a precompiled binding to comrak, a CommonMark
  parser) and `:floki` dependencies; `to_markdown/3` needs neither.

  ## Your own nodes and marks

  A node of the application's own renders as its children — block content as
  blocks, inline content as text — or, for a void node, as the text its
  `:to_text` gives. `:nodes` and `:marks` say otherwise, by name:

      Coelho.Markdown.to_markdown(document, schema,
        nodes: %{mention: fn node, _children -> "@" <> node["attrs"]["handle"] end},
        marks: %{highlight: {"==", "=="}}
      )

  A node override returns the Markdown itself, escaped as it needs; a mark
  override is the pair of strings it is wrapped in.
  """

  alias Coelho.{Attachments, Render, Schema}

  @type opts :: [
          nodes: %{optional(atom()) => (map(), String.t() -> iodata())},
          marks: %{optional(atom()) => {String.t(), String.t()}},
          context: Attachments.context()
        ]

  @doc """
  Renders a validated document as Markdown. `nil` is `""`.
  """
  @spec to_markdown(map() | nil, Schema.t(), opts()) :: String.t()
  def to_markdown(document, schema \\ Schema.default(), opts \\ [])

  def to_markdown(nil, _schema, _opts), do: ""

  def to_markdown(document, %Schema{} = schema, opts) do
    state = %{
      schema: schema,
      nodes: Keyword.get(opts, :nodes, %{}),
      marks: Keyword.get(opts, :marks, %{}),
      context: Keyword.get(opts, :context, %{})
    }

    document
    |> blocks(state)
    |> Enum.join("\n\n")
  end

  @doc """
  Converts Markdown into a validated document, and says what it left behind.

  Through HTML: MDEx renders the Markdown — CommonMark, with GitHub's tables
  and strikethrough — and `Coelho.HTML.from_html/3` imports that under the
  schema, so HTML written inside the Markdown is held to the same rules as
  any other: see its documentation for the warnings.
  """
  @spec from_markdown(String.t(), Schema.t(), keyword()) ::
          {:ok, map(), [Coelho.HTML.warning()]} | {:error, term()}
  def from_markdown(markdown, schema \\ Schema.default(), opts \\ [])
      when is_binary(markdown) do
    unless Code.ensure_loaded?(MDEx) do
      raise ArgumentError, "Coelho.Markdown.from_markdown/3 needs the optional :mdex dependency"
    end

    # `unsafe` passes HTML in the Markdown through to the import, which is
    # where it is judged — and what `to_markdown/3` writes a span as when
    # `**` would not count there.
    html =
      apply(MDEx, :to_html!, [
        markdown,
        [extension: [strikethrough: true, table: true], render: [unsafe: true]]
      ])

    # MDEx ends a line break's `<br />` with a newline, which the import would
    # keep as a space at the start of the next line — one a browser never
    # shows there, and which the document did not hold.
    html
    |> String.replace("<br />\n", "<br />")
    |> Coelho.HTML.from_html(schema, opts)
  end

  # -- Blocks -----------------------------------------------------------------

  # Two lists of one kind in a row are one list to Markdown, blank line or
  # not: the second takes the other marker — `*` after `-`, `)` after `.` —
  # which is what CommonMark ends a list on.
  defp blocks(node, state) do
    node
    |> Map.get("content", [])
    |> Enum.map_reduce(nil, fn child, previous ->
      kind = list_kind(child, state)

      variant =
        if kind != nil and previous != nil and elem(previous, 0) == kind,
          do: 1 - elem(previous, 1),
          else: 0

      # A block written as nothing — an empty paragraph — does not stand
      # between two lists: the one before it is still the one to differ from.
      case block(child, Map.put(state, :variant, variant)) do
        "" -> {"", previous}
        written -> {written, kind && {kind, variant}}
      end
    end)
    |> elem(0)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_kind(%{"type" => type}, state) do
    case spec!(state.schema, type).name do
      name when name in [:bullet_list, :ordered_list] -> name
      _other -> nil
    end
  end

  defp block(%{"type" => type} = node, state) do
    spec = spec!(state.schema, type)

    case Map.fetch(state.nodes, spec.name) do
      {:ok, render} -> render.(node, inner(node, spec, state)) |> IO.iodata_to_binary()
      :error -> block(spec.name, node, spec, state)
    end
  end

  defp block(:paragraph, node, _spec, state), do: node |> trim_edges() |> paragraph(state)

  # An ATX heading is one line, so one holding a line break has no Markdown
  # form: it is written as the HTML Coelho renders for it, which Markdown
  # passes through as a block.
  defp block(:heading, node, _spec, state) do
    node = trim_edges(node)

    if Enum.any?(Map.get(node, "content", []), &(&1["type"] == "hard_break")),
      do: html_block(node, state),
      else: heading(node, state)
  end

  defp block(:blockquote, node, _spec, state) do
    node
    |> blocks(state)
    |> Enum.join("\n\n")
    |> prefix_lines("> ", ">")
  end

  defp block(:bullet_list, node, _spec, state) do
    bullet = if Map.get(state, :variant, 0) == 0, do: "- ", else: "* "
    list(node, fn _index -> bullet end, state)
  end

  defp block(:ordered_list, node, _spec, state) do
    start = Render.attr(node, "start", 1)
    start = if is_integer(start) and start >= 0, do: start, else: 1

    delimiter = if Map.get(state, :variant, 0) == 0, do: ". ", else: ") "
    list(node, fn index -> "#{start + index}" <> delimiter end, state)
  end

  defp block(:code_block, node, _spec, _state) do
    code = node |> Map.get("content", []) |> Enum.map_join(&Map.get(&1, "text", ""))
    fence = String.duplicate("`", max(3, longest_run(code, ?`) + 1))

    language =
      case Render.attr(node, "language") do
        language when is_binary(language) ->
          if language =~ ~r/\A[\w+#.-]+\z/, do: language, else: ""

        _other ->
          ""
      end

    fence <> language <> "\n" <> code <> if(code == "", do: "", else: "\n") <> fence
  end

  defp block(:horizontal_rule, _node, _spec, _state), do: "---"

  defp block(:attachment, node, _spec, state) do
    name =
      Render.attr(node, "filename") |> present() || Render.attr(node, "key") |> present() || ""

    caption = Render.attr(node, "caption") |> present()

    body =
      case Attachments.url(state.context, node) do
        nil -> paragraph_text(name)
        url -> link(escape(name), url, nil)
      end

    if caption, do: body <> "\n\n" <> paragraph_text(caption), else: body
  end

  defp block(:table, node, _spec, state), do: table(node, state)

  # A block of the application's own, or anything the schema calls a block:
  # its content, as blocks when it holds blocks and as a paragraph when it
  # holds inline content.
  defp block(_name, node, spec, state) do
    cond do
      spec.void -> leaf_text(node, spec) |> paragraph_text()
      inline_content?(node, state) -> paragraph(node, state)
      true -> node |> blocks(state) |> Enum.join("\n\n")
    end
  end

  # Markdown cannot begin or end a paragraph with a line break, nor keep
  # whitespace there: what it would drop is not written.
  defp trim_edges(node) do
    content =
      node
      |> Map.get("content", [])
      |> Enum.drop_while(&edge?/1)
      |> Enum.reverse()
      |> Enum.drop_while(&edge?/1)
      |> Enum.reverse()

    Map.put(node, "content", content)
  end

  defp edge?(%{"type" => "hard_break"}), do: true

  defp edge?(%{"type" => "text", "text" => text}) when is_binary(text),
    do: String.trim(text) == ""

  defp edge?(_node), do: false

  defp heading(node, state) do
    level = Render.attr(node, "level", 1)
    level = if is_integer(level) and level in 1..6, do: level, else: 1
    text = node |> paragraph(state) |> escape_closing_hashes()

    # An empty heading says nothing, and not every Markdown reads a bare `#`
    # as one: it goes, as an empty paragraph does.
    if String.trim(text) == "", do: "", else: String.duplicate("#", level) <> " " <> text
  end

  # Coelho's own HTML for the node, which escapes everything a writer typed.
  # An HTML block ends at a blank line, so no line break may survive in it:
  # the newlines a text holds become the entity they stand for.
  defp html_block(node, state) do
    node
    |> Render.to_html(state.schema, context: state.context)
    |> String.replace("\n", "&#10;")
  end

  defp inner(node, spec, state) do
    cond do
      spec.void -> ""
      spec.inline or inline_content?(node, state) -> inline(node, state)
      true -> node |> blocks(state) |> Enum.join("\n\n")
    end
  end

  defp inline_content?(node, state) do
    node
    |> Map.get("content", [])
    |> Enum.any?(fn child -> spec!(state.schema, child["type"]).inline end)
  end

  # Items separated by a single line break while every one is a single
  # paragraph — a tight list, rendered without <p> — and by a blank line
  # otherwise. The continuation of an item is indented by the width of its
  # marker, which is what makes it the item's and not the next block's.
  defp list(node, marker, state) do
    items = Map.get(node, "content", [])

    # Tight while every item is one paragraph, possibly followed by lists:
    # the shape a writer makes, and the one a blank line would turn loose.
    tight? =
      Enum.all?(items, fn item ->
        case Map.get(item, "content", []) do
          [first | rest] ->
            spec!(state.schema, first["type"]).name == :paragraph and
              Enum.all?(rest, &interrupts_paragraph?(&1, state))

          [] ->
            false
        end
      end)

    separator = if tight?, do: "\n", else: "\n\n"

    items
    |> Enum.with_index()
    |> Enum.map_join(separator, fn {item, index} ->
      mark = marker.(index)
      body = item |> blocks(state) |> Enum.join(separator)

      mark <> indent(body, String.duplicate(" ", String.length(mark)))
    end)
  end

  # Only these follow a paragraph on the very next line without a blank one:
  # a bullet list, and an ordered list starting at 1. One starting anywhere
  # else is read as more of the paragraph's text.
  defp interrupts_paragraph?(node, state) do
    case spec!(state.schema, node["type"]).name do
      :bullet_list -> true
      :ordered_list -> Render.attr(node, "start", 1) == 1
      _other -> false
    end
  end

  # GitHub splits a row on every `|` that is not escaped, before anything
  # else is read — inside a code span or a link's destination too — and
  # `\|` there is a `|` again. So every pipe not already escaped is.
  defp escape_pipes(cell) do
    cell
    |> String.graphemes()
    |> Enum.reduce({[], false}, fn
      "|", {out, false} -> {["|", "\\" | out], false}
      "\\", {out, escaped?} -> {["\\" | out], not escaped?}
      char, {out, _escaped?} -> {[char | out], false}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # GitHub's pipe tables: the first row is the header, whatever it held, and
  # a cell is its text on one line. Spans are not expressible and are lost.
  defp table(node, state) do
    rows =
      for row <- Map.get(node, "content", []) do
        for cell <- Map.get(row, "content", []) do
          cell
          |> blocks(Map.put(state, :table?, true))
          |> Enum.join(" ")
          # A cell is one line: a line break in it is HTML's.
          |> String.replace("\\\n", "<br>")
          |> String.replace("\n", " ")
          |> escape_pipes()
        end
      end

    case rows do
      [] ->
        ""

      [header | body] ->
        width = rows |> Enum.map(&length/1) |> Enum.max()
        pad = fn row -> row ++ List.duplicate("", width - length(row)) end
        line = fn row -> "| " <> Enum.join(pad.(row), " | ") <> " |" end

        Enum.join(
          [line.(header), "|" <> String.duplicate(" --- |", width) | Enum.map(body, line)],
          "\n"
        )
    end
  end

  # -- Inline -----------------------------------------------------------------

  defp paragraph(node, state), do: node |> inline(state) |> escape_line_starts()

  defp paragraph_text(text), do: text |> escape() |> escape_line_starts()

  # Text with its marks, in two passes. The first turns the run of inline
  # nodes into a tree of spans, each mark opened once for the run of nodes it
  # covers — `**a b**`, not `**a****b**`. The second writes each span.
  defp inline(node, state) do
    node
    |> Map.get("content", [])
    |> Enum.flat_map(&tokens(&1, state))
    |> group(0)
    |> render_spans(:edge, :edge)
  end

  # -- Tokens: `{kind, markdown, marks}`, or `:break`.

  defp tokens(%{"type" => type} = node, state) do
    spec = spec!(state.schema, type)
    marks = marks(node, state)

    cond do
      Map.has_key?(state.nodes, spec.name) ->
        markdown = state.nodes[spec.name].(node, inner(node, spec, state))
        [{:atom, IO.iodata_to_binary(markdown), marks}]

      spec.text ->
        text_tokens(Map.get(node, "text", ""), marks, table?(state))

      # A line break carries no marks — it has none in the document, and
      # the HTML renderer writes it outside them — so spans close around it.
      spec.name == :hard_break ->
        [:break]

      spec.name == :image ->
        [{:atom, image(node, table?(state)), marks}]

      true ->
        own_tokens(node, spec, marks, state)
    end
  end

  defp image(node, table?) do
    alt = Render.attr(node, "alt") |> present() || ""
    src = Render.attr(node, "src") |> Render.safe_url() || ""
    "!" <> link(escape(alt, table?), src, Render.attr(node, "title") |> present(), table?)
  end

  defp table?(state), do: Map.get(state, :table?, false)

  # An inline node of the application's own: what its `:to_text` says when it
  # is void, and its content under its own marks as well when it is not.
  defp own_tokens(node, %{void: true} = spec, marks, state) do
    case leaf_text(node, spec) do
      "" -> []
      text -> text_tokens(text, marks, table?(state))
    end
  end

  defp own_tokens(node, _spec, marks, state) do
    node
    |> Map.get("content", [])
    |> Enum.flat_map(&tokens(&1, state))
    |> Enum.map(fn
      {kind, value, inner} -> {kind, value, marks ++ inner}
      :break -> :break
    end)
  end

  # Code is a span of its own, written whole: nothing inside it is escaped
  # and no other mark can start or end inside it.
  defp text_tokens(text, marks, table?) do
    text = String.replace(text, ["\r\n", "\n", "\r", "\t"], " ")

    case Enum.split_with(marks, &(&1.name == :code)) do
      {[_code | _], others} -> [{:atom, code_span(text, table?), others}]
      {[], _all} -> [{:text, text |> escape(table?) |> escape_trailing_bang(), marks}]
    end
  end

  # Marks as maps carrying their delimiters, outermost first: the order the
  # schema declares them, which is the order a validated document keeps.
  defp marks(node, state) do
    for mark <- Map.get(node, "marks", []) do
      spec = mark_spec!(state.schema, mark["type"])

      spec
      |> delimiters(mark, state)
      |> Map.merge(%{name: spec.name, key: {mark["type"], Map.get(mark, "attrs")}})
    end
  end

  defp delimiters(spec, mark, state) do
    case {Map.fetch(state.marks, spec.name), spec.name} do
      {{:ok, {open, close}}, _name} -> %{kind: :fixed, open: open, close: close}
      {:error, :bold} -> %{kind: :emphasis, open: "**", close: "**", tag: "strong"}
      {:error, :italic} -> %{kind: :emphasis, open: "*", close: "*", tag: "em"}
      {:error, :strike} -> %{kind: :emphasis, open: "~~", close: "~~", tag: "del"}
      {:error, :code} -> %{kind: :fixed, open: "", close: ""}
      {:error, :link} -> %{kind: :fixed, open: "[", close: link_tail(mark, table?(state))}
      {:error, _custom} -> %{kind: :fixed, open: "", close: ""}
    end
  end

  defp link_tail(mark, table?) do
    href = Render.attr(mark, "href") |> Render.safe_url() || ""
    destination(href, Render.attr(mark, "title") |> present(), table?)
  end

  # -- Spans: consecutive tokens sharing the mark at `depth` become one span
  # of it.

  defp group(tokens, depth) do
    tokens
    |> Enum.chunk_by(&(&1 |> token_marks() |> Enum.at(depth) |> key()))
    |> Enum.flat_map(fn [first | _] = chunk ->
      case first |> token_marks() |> Enum.at(depth) do
        nil -> Enum.map(chunk, &leaf/1)
        mark -> [{:span, mark, group(chunk, depth + 1)}]
      end
    end)
  end

  defp token_marks(:break), do: []
  defp token_marks({_kind, _value, marks}), do: marks

  defp key(nil), do: nil
  defp key(mark), do: mark.key

  defp leaf(:break), do: :break
  defp leaf({kind, value, _marks}), do: {kind, value}

  # -- Writing the tree.
  #
  # `**`, `*` and `~~` only count as delimiters when the characters around
  # them allow it: CommonMark's flanking rules. A span is written with them
  # when that is certain, and as the equivalent HTML element otherwise —
  # `<strong>`, `<em>`, `<del>` are Markdown too, and come back through the
  # import the same way. So `**word**` stays readable, and a bold `*b` right
  # after a letter is `a<strong>\*b</strong>`, which is what it has to be.

  defp render_spans(children, outer_before, outer_after) do
    children
    |> Enum.with_index()
    |> Enum.reduce("", fn {child, index}, out ->
      before =
        cond do
          out == "" -> outer_before
          space?(String.last(out)) -> :space
          true -> {:char, String.last(out)}
        end

      after_ =
        case Enum.at(children, index + 1) do
          nil -> outer_after
          :break -> :space
          {:span, _mark, _children} -> :span
          {_kind, value} -> if space?(String.first(value)), do: :space, else: :other
        end

      out <> line_start(out, outer_before, render_child(child, before, after_))
    end)
  end

  # Markdown drops the spaces a line begins with, which a line break's next
  # line may well hold: written as the entity, a space is kept.
  defp line_start(out, outer_before, written) do
    at_line_start? = String.ends_with?(out, "\\\n") or (out == "" and outer_before == :edge)

    if at_line_start? do
      String.replace(written, ~r/\A +/, &String.duplicate("&#32;", byte_size(&1)))
    else
      written
    end
  end

  defp render_child(:break, _before, _after), do: "\\\n"
  defp render_child({_kind, value}, _before, _after), do: value

  defp render_child({:span, %{kind: :emphasis} = mark, children}, before, after_) do
    inner = render_spans(children, :delimiter, :delimiter)

    if delimiters_hold?(inner, before, after_),
      do: mark.open <> inner <> mark.close,
      else: "<" <> mark.tag <> ">" <> inner <> "</" <> mark.tag <> ">"
  end

  defp render_child({:span, mark, children}, _before, _after) do
    mark.open <> render_spans(children, :delimiter, :delimiter) <> mark.close
  end

  # The opening delimiter is left-flanking when the character after it is a
  # letter or digit, or punctuation after a space or the edge of the line;
  # the closing one mirrors it. A span that begins or ends with a space has
  # no delimiter that counts at all, so it is HTML, and keeps the space. And
  # no run of `*` or `~` may touch another, or the two merge into one.
  defp delimiters_hold?(inner, before, after_) do
    first = String.first(inner)
    last = String.last(inner)

    not space?(first) and not space?(last) and
      (word?(first) or before in [:edge, :space]) and
      (word?(last) or after_ in [:edge, :space]) and
      not touches_run?(before) and after_ != :span
  end

  defp space?(char), do: char != nil and String.match?(char, ~r/\A\s\z/u)
  defp word?(char), do: char != nil and String.match?(char, ~r/\A[\p{L}\p{N}]\z/u)

  defp touches_run?({:char, char}), do: char in ["*", "~", "_"]
  defp touches_run?(_before), do: false

  # In a table cell no `|` may stand in the Markdown, and a code span cannot
  # escape one there for every backslash before it: GitHub reads `\|` back as
  # `|` only after an odd run of them. So a code span in a cell is `<code>`,
  # its punctuation written as entities, which neither split the row nor read
  # as Markdown.
  defp code_span(text, true) do
    entities =
      text
      |> String.to_charlist()
      |> Enum.map(fn char ->
        if char in ?!..?/ or char in ?:..?@ or char in ?[..?` or char in ?{..?~,
          do: "&##{char};",
          else: <<char::utf8>>
      end)

    "<code>" <> IO.iodata_to_binary(entities) <> "</code>"
  end

  defp code_span(text, false) do
    fence = String.duplicate("`", longest_run(text, ?`) + 1)

    # CommonMark strips one space from each side of a code span's content
    # that has one on both, and a backtick against the fence would lengthen
    # it: padding with a space on both sides answers both.
    # Content that is only spaces is never stripped, so it is never padded.
    pad =
      if String.trim(text, " ") != "" and
           (String.starts_with?(text, ["`", " "]) or String.ends_with?(text, ["`", " "])),
         do: " ",
         else: ""

    fence <> pad <> text <> pad <> fence
  end

  defp mark_spec!(schema, type) do
    case Schema.fetch_mark_spec(schema, type) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "cannot render unknown mark type #{inspect(type)}"
    end
  end

  # -- Pieces -----------------------------------------------------------------

  defp leaf_text(node, spec) do
    case spec.to_text do
      nil -> ""
      fun when is_function(fun, 1) -> fun.(node) |> IO.iodata_to_binary() |> String.trim()
      text when is_binary(text) -> String.trim(text)
    end
  end

  defp link(text, url, title, table? \\ false),
    do: "[" <> text <> destination(url, title, table?)

  # `](<url> "title")`: the angle brackets let a destination hold spaces and
  # parentheses, and the title is quoted with its own quotes escaped.
  defp destination(url, title, table?) do
    title = if title, do: ~s( ") <> escape_title(title, table?) <> ~s("), else: ""
    "](<" <> escape_url(url, table?) <> ">" <> title <> ")"
  end

  defp escape_title(title, table?) do
    title
    |> String.replace("|", if(table?, do: "&#124;", else: "|"))
    |> String.replace(["\\", ~s(")], &("\\" <> &1))
    |> String.replace(["\r\n", "\n", "\r"], " ")
  end

  # Inside `<…>` only the brackets and a line break end the destination.
  # In a table cell a destination's `|` is the same URL percent-encoded.
  defp escape_url(url, true), do: url |> String.replace("|", "%7C") |> escape_url(false)

  defp escape_url(url, false),
    do: url |> String.replace("\\", "\\\\") |> String.replace(["<", ">", "\n"], &escape_char/1)

  defp escape_char("\n"), do: "%0A"
  defp escape_char(char), do: "\\" <> char

  # What CommonMark reads as syntax anywhere in a line. A backslash before
  # any ASCII punctuation is that character, so escaping too much is safe and
  # escaping too little is not; `.`, `(`, `-` and the like are only syntax at
  # the start of a line, which `escape_line_starts/1` handles.
  @escaped ~c"\\`*_[]<>~|&"

  defp escape(text, table? \\ false) do
    text
    |> String.replace(["\r\n", "\n", "\r", "\t"], " ")
    |> String.to_charlist()
    |> Enum.map(fn
      # In a table cell a typed `|` is its entity: escaped with a backslash
      # it would come back as one only after an even run of backslashes.
      ?| when table? -> "&#124;"
      char when char in @escaped -> [?\\, char]
      char -> char
    end)
    |> List.to_string()
  end

  # A `!` that ends a text node may be followed by a link, and `![` opens an
  # image. Inside the text a `[` is already escaped, so only the last one
  # needs it.
  # Every `!` here is one the writer typed: `escape/1` never escapes it, and
  # a backslash before it is an escaped backslash of theirs.
  defp escape_trailing_bang(text) do
    if String.ends_with?(text, "!"),
      do: String.slice(text, 0..-2//1) <> "\\!",
      else: text
  end

  # A line that would open a block instead of continuing the paragraph: a
  # heading, a quote, a list, a thematic break or setext underline, a fence.
  defp escape_line_starts(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      case Regex.run(~r/\A(\s*)(#|>|\+|-|=|\d{1,9}[.)])(.*)\z/s, line) do
        [_all, space, mark, rest] -> space <> escape_mark(mark) <> rest
        nil -> line
      end
    end)
  end

  defp escape_mark(mark) do
    case Regex.run(~r/\A(\d+)([.)])\z/, mark) do
      [_all, digits, dot] -> digits <> "\\" <> dot
      nil -> "\\" <> mark
    end
  end

  # `## Title ##` has a closing sequence, which CommonMark strips: a heading
  # whose text ends in `#` would lose it.
  defp escape_closing_hashes(text) do
    if String.ends_with?(text, "#") and not String.ends_with?(text, "\\#"),
      do: String.slice(text, 0..-2//1) <> "\\#",
      else: text
  end

  defp prefix_lines(text, prefix, empty) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> empty
      line -> prefix <> line
    end)
  end

  defp indent(text, by) do
    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map_join("\n", fn
      {line, 0} -> line
      {"", _index} -> ""
      {line, _index} -> by <> line
    end)
  end

  defp longest_run(text, char) do
    text
    |> String.to_charlist()
    |> Enum.chunk_by(&(&1 == char))
    |> Enum.filter(&(hd(&1) == char))
    |> Enum.map(&length/1)
    |> Enum.max(fn -> 0 end)
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp spec!(schema, type) do
    case Schema.fetch_node_spec(schema, type) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "cannot render unknown node type #{inspect(type)}"
    end
  end
end
