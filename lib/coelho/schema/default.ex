defmodule Coelho.Schema.Default do
  @moduledoc """
  The schema Coelho ships with.

  It covers what an application typically needs out of the box — paragraphs,
  headings, lists, quotes, code blocks, images and the usual inline marks —
  and is meant to be copied and adapted rather than extended in place.

  ## What the `link` mark emits

  An `href` and a `title`, and nothing else. In particular **no `target` and
  no `rel`**: a document is not necessarily rendered into a page where
  opening a new tab makes sense, and a `target="_blank"` without
  `rel="noopener"` hands the opened page a handle on the opener. Rather than
  guess, the shipped renderer emits neither.

  An application that wants them says so per render, and must set both:

      Coelho.to_html(document,
        marks: %{
          link: fn mark, inner ->
            Coelho.Render.tag(
              "a",
              [
                {"href", Coelho.Render.safe_url(Coelho.Render.attr(mark, "href"))},
                {"target", "_blank"},
                {"rel", "noopener noreferrer"}
              ],
              inner
            )
          end
        }
      )

  The `href` still goes through `Coelho.Render.safe_url/1` there, because a
  stored document is not re-validated on the way out.

  ## Alignment

  `paragraph`, `heading` and `list_item` carry an `align` attribute, one of
  `left`, `center`, `right` or `justify`, rendered as a `text-align` style
  and read back from either a `style` or an `align` attribute on import. It
  is absent from the document when unset, and re-checked against the closed
  list at render time.

  *How* it renders is part of the attribute's declaration — `:render_as`,
  see `Coelho.Schema.Attr` — rather than a render function, so the browser
  applies the same answer and an application can change it without writing
  any JavaScript. An inline style is what ships because it needs no
  stylesheet: the HTML works in an email, a feed, an export. It is also what
  a page's own CSS cannot override, so an application that would rather own
  alignment in its stylesheet asks for a class map instead — once, for the
  three blocks that carry the attribute:

      Coelho.Schema.Default.build(
        align: {:class, %{"center" => "text-center", "right" => "text-right"}}
      )

  The schema is built once and kept in `:persistent_term`, since it is
  immutable and read on every render.
  """

  alias Coelho.Schema

  @doc """
  Returns the default schema, building it on first use.
  """
  @spec schema() :: Schema.t()
  def schema do
    case :persistent_term.get({__MODULE__, :schema}, nil) do
      nil ->
        schema = build()
        :persistent_term.put({__MODULE__, :schema}, schema)
        schema

      schema ->
        schema
    end
  end

  @doc """
  Builds the default schema without consulting the cache.

  ## Options

    * `:align` — how the `align` attribute reaches the DOM, in the form
      `Coelho.Schema.Attr` takes for `:render_as`. Defaults to
      `{:style, "text-align"}`.

  An inline style is unanswerable by a stylesheet, so an application that
  would rather own alignment in CSS says so once, here, rather than
  redeclaring the three blocks that carry the attribute:

      Coelho.Schema.Default.build(
        align: {:class, %{"center" => "text-center", "right" => "text-right"}}
      )

  The result is not cached — `schema/0` caches the default one. Build yours
  once at compile time, as an application with any custom schema already
  does.
  """
  @spec build(keyword()) :: Schema.t()
  def build(opts \\ []) do
    align = Keyword.get(opts, :align, {:style, "text-align"})

    Schema.new(
      top_node: :doc,
      nodes:
        [
          doc: [content: "block+"],
          paragraph: [
            content: "inline*",
            group: "block",
            attrs: [align: align_attr(align)],
            render: {"p", []},
            parse: [{"p", &__MODULE__.parse_align/1}]
          ],
          heading: [
            content: "inline*",
            group: "block",
            attrs: [
              level: [default: 1, validate: {:one_of, [1, 2, 3, 4, 5, 6]}],
              align: align_attr(align)
            ],
            render: {&__MODULE__.heading_tag/1, []},
            parse: Enum.map(1..6, &{"h#{&1}", Function.capture(__MODULE__, :"parse_h#{&1}", 1)})
          ],
          blockquote: [
            content: "block+",
            group: "block",
            render: {"blockquote", []},
            parse: ["blockquote"]
          ],
          bullet_list: [content: "list_item+", group: "block", render: {"ul", []}, parse: ["ul"]],
          ordered_list: [
            content: "list_item+",
            group: "block",
            attrs: [start: [default: 1, validate: :integer]],
            render: {"ol", &__MODULE__.ordered_list_attrs/1},
            parse: [{"ol", &__MODULE__.parse_ordered_list/1}]
          ],
          list_item: [
            content: "paragraph block*",
            attrs: [align: align_attr(align)],
            render: {"li", []},
            parse: [{"li", &__MODULE__.parse_align/1}]
          ],
          code_block: [
            content: "text*",
            group: "block",
            marks: :none,
            attrs: [language: [default: nil, validate: {:nullable, &__MODULE__.language/1}]],
            render: &__MODULE__.render_code_block/2,
            parse: ["pre"]
          ],
          horizontal_rule: [group: "block", void: true, render: {"hr", []}, parse: ["hr"]],
          image: [
            group: "inline",
            inline: true,
            void: true,
            attrs: [
              src: [required: true, validate: :safe_url],
              alt: [default: nil, validate: {:nullable, :string}],
              title: [default: nil, validate: {:nullable, :string}]
            ],
            render: {"img", &__MODULE__.image_attrs/1},
            parse: [{"img", &__MODULE__.parse_image/1}]
          ],
          attachment: [
            group: "block",
            void: true,
            attrs: [
              key: [required: true, validate: :string],
              filename: [default: nil, validate: {:nullable, :string}],
              content_type: [default: nil, validate: {:nullable, :string}],
              byte_size: [default: nil, validate: {:nullable, :integer}],
              alt: [default: nil, validate: {:nullable, :string}],
              caption: [default: nil, validate: {:nullable, :string}]
            ],
            render: &__MODULE__.render_attachment/3,
            render_inline: &__MODULE__.inline_attachment/3,
            to_text: &__MODULE__.attachment_text/1
          ],
          hard_break: [
            group: "inline",
            inline: true,
            void: true,
            render: {"br", []},
            to_text: "\n",
            parse: ["br"]
          ],
          text: [group: "inline", inline: true, text: true]
        ] ++ table_nodes(Keyword.get(opts, :tables, false)),
      marks: [
        bold: [render: {"strong", []}, parse: ~w(strong b)],
        italic: [render: {"em", []}, parse: ~w(em i)],
        strike: [render: {"s", []}, parse: ~w(s del strike)],
        code: [render: {"code", []}, parse: ["code"]],
        link: [
          attrs: [
            href: [required: true, validate: :safe_url],
            title: [default: nil, validate: {:nullable, :string}]
          ],
          render: {"a", &__MODULE__.link_attrs/1},
          parse: [{"a", &__MODULE__.parse_link/1}]
        ]
      ]
    )
  end

  # Declared last so that nothing else moves: `block+` is satisfied by the
  # schema's first suitable block, which is how a bare `Hello` becomes a
  # paragraph and not a table.
  #
  # Off unless asked for, and the reason is the browser rather than the
  # server. Everything a stored table needs is here — it validates, renders,
  # extracts to text and survives an import that used to drop it with a
  # warning — but the editor has no cell navigation and no row or column
  # commands yet, so a table is easier to write in the HTML an application is
  # migrating than in the editor it is migrating to.
  defp table_nodes(false), do: []

  defp table_nodes(true) do
    cell = [
      content: "block+",
      attrs: [
        colspan: [default: 1, validate: &__MODULE__.span/1],
        rowspan: [default: 1, validate: &__MODULE__.span/1]
      ]
    ]

    [
      table: [
        content: "table_row+",
        group: "block",
        render: {"table", []},
        parse: ["table"]
      ],
      table_row: [
        content: "(table_cell | table_header)+",
        render: {"tr", []},
        parse: ["tr"]
      ],
      table_cell:
        cell ++
          [render: {"td", &__MODULE__.cell_attrs/1}, parse: [{"td", &__MODULE__.parse_cell/1}]],
      table_header:
        cell ++
          [render: {"th", &__MODULE__.cell_attrs/1}, parse: [{"th", &__MODULE__.parse_cell/1}]]
    ]
  end

  # A span is a count of cells, and it is bounded for the same reason every
  # other bound exists: `colspan="1000000"` is one attribute a writer never
  # typed and a table nothing downstream can lay out.
  @max_span 1000

  @doc false
  def span(value) when is_integer(value) and value >= 1 and value <= @max_span, do: :ok

  def span(_value), do: {:error, "must be a whole number of cells, from 1 to #{@max_span}"}

  @doc false
  def cell_attrs(node) do
    [{"colspan", span_of(node, "colspan")}, {"rowspan", span_of(node, "rowspan")}]
  end

  # Absent when it is one, which is what it means, and clamped rather than
  # trusted — a row was written under whatever schema was in force then.
  defp span_of(node, name) do
    case attr(node, name, 1) do
      value when is_integer(value) and value > 1 and value <= @max_span -> value
      _one_or_not_a_span -> nil
    end
  end

  @doc false
  def parse_cell(attrs) do
    for name <- ~w(colspan rowspan),
        {value, ""} <- [Integer.parse(Map.get(attrs, name, "1"))],
        value > 1,
        into: %{},
        do: {name, min(value, @max_span)}
  end

  # Alignment is a property of a block of text, not of one kind of block, so
  # it is declared once and given to each block that can carry it. Coelho has
  # no mechanism for an attribute shared across node types — this is that
  # mechanism, and it is a function returning a declaration.
  #
  # How the value reaches the DOM is part of that declaration rather than a
  # render function, so the browser is handed the same answer and an
  # application can change it by declaring its own attribute — see
  # `Coelho.Schema.Attr`. The shipped form is the inline style, which needs
  # no stylesheet to work anywhere the HTML travels.
  @aligns ~w(left center right justify)

  defp align_attr(render_as) do
    [
      default: nil,
      validate: {:nullable, {:one_of, @aligns}},
      render_as: render_as
    ]
  end

  @doc false
  def parse_align(attrs) do
    case align_of(attrs) do
      nil -> %{}
      align -> %{"align" => align}
    end
  end

  defp align_of(attrs) do
    declared = attrs |> Map.get("align", "") |> String.trim() |> String.downcase()

    styled =
      case Regex.run(~r/text-align\s*:\s*([a-z]+)/i, Map.get(attrs, "style", "")) do
        [_match, align] -> String.downcase(align)
        nil -> ""
      end

    Enum.find([styled, declared], &(&1 in @aligns))
  end

  for level <- 1..6 do
    @doc false
    def unquote(:"parse_h#{level}")(attrs),
      do: attrs |> parse_align() |> Map.put("level", unquote(level))
  end

  # A heading's *tag* is what its level decides, which is why it is a
  # function rather than a name. Written as a render function instead —
  # building the whole element — it would reach neither the spec's `:class`
  # nor the alignment its own attribute declares.
  #
  # Nothing downstream escapes a tag name. Validation already bounds `level`,
  # but a row written under an older or looser schema still renders through
  # today's renderer, so the clamp stays. Every renderer below follows the
  # same rule: nothing read out of a stored document is trusted to be well
  # typed or safe.
  #
  # The 1 below is this schema's own `:level` default, and it has to be: a
  # render function is handed the node, never the schema. A schema that
  # redeclares `heading` with another default has to bring its own render
  # with it — the browser reads the exported default and would draw a level
  # this prints as another. See `Coelho.Render.attr/3`.
  @doc false
  def heading_tag(node) do
    level =
      case attr(node, "level", 1) do
        level when is_integer(level) and level in 1..6 -> level
        _other -> 1
      end

    "h" <> Integer.to_string(level)
  end

  # The name of a language, and not a list of classes. `language-` is a
  # prefix a stylesheet and a highlighter both look for, so whatever follows
  # it lands in the `class` attribute of every code block on the page: a
  # value carrying a space contributes class names of its own choosing —
  # whatever the application's stylesheet happens to attach to them.
  #
  # Wide enough for the names that exist: `c++`, `f#`, `objective-c`,
  # `html+erb`. Narrow enough to be one token.
  @language ~r/\A[A-Za-z0-9_+#.-]{1,32}\z/

  @doc false
  def language(value) when is_binary(value) do
    if Regex.match?(@language, value),
      do: :ok,
      else: {:error, "must be the name of a language, without spaces"}
  end

  def language(_value), do: {:error, "must be a string"}

  @doc false
  def render_code_block(node, inner) do
    # Clamped here as well as validated, for the same reason `heading_tag/1`
    # clamps its level: what is already stored was written under whatever
    # schema was in force then, and it is today's renderer that puts it on
    # the page.
    class =
      case attr(node, "language", nil) do
        language when is_binary(language) ->
          if Regex.match?(@language, language), do: "language-" <> language

        _other ->
          nil
      end

    Coelho.Render.tag("pre", [], Coelho.Render.tag("code", [{"class", class}], inner))
  end

  @doc false
  def render_attachment(node, _inner, context) do
    url = Coelho.Attachments.url(context, node)
    label = attr(node, "filename", nil) || attr(node, "key", "")

    body =
      cond do
        is_nil(url) ->
          # A key that no longer resolves degrades to its filename rather
          # than to a broken image.
          Coelho.Render.tag("span", [{"class", "coelho-attachment-missing"}], escape(label))

        image?(attr(node, "content_type", nil)) ->
          Coelho.Render.void_tag("img", [{"src", url}, {"alt", attr(node, "alt", nil)}])

        true ->
          Coelho.Render.tag("a", [{"href", url}], escape(label))
      end

    # Drawn when there is a caption to draw, which is what the inline form
    # and the text extraction both ask: `nil` is not the only way a stored
    # row says there is none, and an empty `figcaption` on a public page is
    # the three of them disagreeing about one row.
    caption =
      case present(attr(node, "caption", nil)) do
        nil -> []
        caption -> Coelho.Render.tag("figcaption", [], escape(caption))
      end

    Coelho.Render.tag("figure", [{"class", "coelho-attachment"}], [body, caption])
  end

  @doc false
  def inline_attachment(node, _inner, context) do
    # A `<figure>` is not legal where only inline elements are, and an
    # attachment has no children to unwrap towards — it is `void: true`, and
    # everything it shows comes out of the render function above. So it says
    # here what it is inline: the image if there is one, otherwise its name,
    # and the caption's words after it.
    #
    # Contributing nothing would be worse than wrong: `Coelho.blank?/2`
    # counts an attachment as content, and a document answering "yes there is
    # something" and then rendering nothing is two functions of the same
    # library contradicting each other.
    url = Coelho.Attachments.url(context, node)

    # The same three shapes the page renders: `<img>` and `<a>` are both legal
    # inline, and dropping the href would lose the download link a card
    # excerpt is there to offer. And always an element, never bare text that
    # can be empty — `filename` accepts `""` and so does `key`, and a
    # contribution of nothing is dropped when the blocks are joined, so the
    # attachment would vanish from a document `Coelho.blank?/2` calls
    # non-blank.
    cond do
      url && image?(attr(node, "content_type", nil)) ->
        Coelho.Render.void_tag("img", [{"src", url}, {"alt", attr(node, "alt", nil)}])

      url ->
        Coelho.Render.tag("a", [{"href", url}], escape(label(node)))

      true ->
        Coelho.Render.tag("span", [{"class", "coelho-attachment-missing"}], escape(label(node)))
    end
    |> then(&with_caption(&1, node))
  end

  defp label(node) do
    case attr(node, "filename", nil) do
      name when is_binary(name) and name != "" -> name
      _other -> attr(node, "key", "")
    end
  end

  # `""` is a caption the schema accepts, and appending it leaves a trailing
  # space that the join then puts a separator after — two spaces, or a space
  # and a `<br>`.
  defp with_caption(body, node) do
    case attr(node, "caption", nil) do
      caption when is_binary(caption) and caption != "" -> [body, " ", escape(caption)]
      _other -> body
    end
  end

  @doc false
  def attachment_text(node) do
    case present(attr(node, "caption", nil)) || present(attr(node, "filename", nil)) do
      nil -> []
      text -> [text, "\n"]
    end
  end

  # The first of the two that is text somebody typed. `||` on the raw
  # attributes answers a different question: every value is truthy but
  # `false` and `nil`, so a caption a looser row wrote — a number, a map —
  # would take the place of a filename that is right there, and the search
  # index would lose the only name the row has. `""` is a caption the schema
  # accepts and is nothing to show, which is how `label/1` and
  # `with_caption/2` already read it.
  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp image?(content_type) when is_binary(content_type),
    do: String.starts_with?(content_type, "image/")

  defp image?(_content_type), do: false

  defp escape(value) when is_binary(value), do: Coelho.Render.escape(value)

  # An attachment draws its own markup, so it escapes its own text rather
  # than going through `attributes/1` — and it reads that text out of a
  # stored row, which can hold whatever the validator in force then allowed.
  # `to_string/1` raises on a map, and this is a public page: what cannot be
  # a string is nothing, the same answer the attributes get.
  #
  # Which is why `nil` and a boolean come first and answer nothing at all.
  # They say whether there is something to show rather than what to show,
  # and `attributes/1` reads them that way too — one row draws a caption
  # through here and an `alt` through there, and a `figcaption` reading
  # `false` is the two of them disagreeing.
  defp escape(value) when is_nil(value) or is_boolean(value), do: []

  defp escape(value) when is_number(value) or is_atom(value),
    do: Coelho.Render.escape(to_string(value))

  defp escape(_value), do: []

  # Every term in a schema has to be escapable, so that a schema can live in a
  # module attribute: remote captures qualify, closures do not.
  @doc false
  def parse_image(attrs), do: Coelho.HTML.take(attrs, ~w(src alt title))

  @doc false
  def parse_link(attrs), do: Coelho.HTML.take(attrs, ~w(href title))

  @doc false
  def parse_ordered_list(attrs) do
    case Integer.parse(Map.get(attrs, "start", "1")) do
      {start, ""} -> %{"start" => start}
      _ -> %{}
    end
  end

  @doc false
  def ordered_list_attrs(node) do
    case attr(node, "start", 1) do
      1 -> []
      start -> [{"start", start}]
    end
  end

  @doc false
  def image_attrs(node) do
    [
      {"src", Coelho.Render.safe_url(attr(node, "src", nil))},
      {"alt", attr(node, "alt", nil)},
      {"title", attr(node, "title", nil)}
    ]
  end

  @doc false
  def link_attrs(mark) do
    [
      {"href", Coelho.Render.safe_url(attr(mark, "href", nil))},
      {"title", attr(mark, "title", nil)}
    ]
  end

  defp attr(node, name, default), do: Coelho.Render.attr(node, name, default)
end
