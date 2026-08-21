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
  """
  @spec build() :: Schema.t()
  def build do
    Schema.new(
      top_node: :doc,
      nodes: [
        doc: [content: "block+"],
        paragraph: [
          content: "inline*",
          group: "block",
          attrs: [align: align_attr()],
          render: {"p", &__MODULE__.align_attrs/1},
          parse: [{"p", &__MODULE__.parse_align/1}]
        ],
        heading: [
          content: "inline*",
          group: "block",
          attrs: [
            level: [default: 1, validate: {:one_of, [1, 2, 3, 4, 5, 6]}],
            align: align_attr()
          ],
          render: &__MODULE__.render_heading/2,
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
          attrs: [align: align_attr()],
          render: {"li", &__MODULE__.align_attrs/1},
          parse: [{"li", &__MODULE__.parse_align/1}]
        ],
        code_block: [
          content: "text*",
          group: "block",
          marks: :none,
          attrs: [language: [default: nil, validate: {:nullable, :string}]],
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
      ],
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

  # Alignment is a property of a block of text, not of one kind of block, so
  # it is declared once and given to each block that can carry it. Coelho has
  # no mechanism for an attribute shared across node types — this is that
  # mechanism, and it is a function returning a declaration.
  @aligns ~w(left center right justify)

  defp align_attr, do: [default: nil, validate: {:nullable, {:one_of, @aligns}}]

  @doc false
  def align_attrs(node), do: [{"style", align_style(node)}]

  # The value goes into a `style` attribute, so it is re-checked against the
  # closed list here rather than trusted: validation bounded it on the way
  # in, and a row written under a looser schema still renders through this.
  defp align_style(node) do
    case Coelho.Render.attr(node, "align") do
      align when align in @aligns -> "text-align:" <> align
      _other -> nil
    end
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

  @doc false
  def render_heading(node, inner) do
    Coelho.Render.tag(
      "h" <> Integer.to_string(heading_level(node)),
      align_attrs(node),
      inner
    )
  end

  # The renderer builds a tag *name* here, which nothing downstream escapes.
  # Validation already bounds `level`, but a row written under an older or
  # looser schema still renders through today's renderer, so the clamp stays.
  # Every renderer below follows the same rule: nothing read out of a stored
  # document is trusted to be well typed or safe.
  defp heading_level(node) do
    case attr(node, "level", 1) do
      level when is_integer(level) and level in 1..6 -> level
      _ -> 1
    end
  end

  @doc false
  def render_code_block(node, inner) do
    class =
      case attr(node, "language", nil) do
        language when is_binary(language) -> "language-" <> language
        _ -> nil
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

    caption =
      case attr(node, "caption", nil) do
        nil -> []
        caption -> Coelho.Render.tag("figcaption", [], escape(caption))
      end

    Coelho.Render.tag("figure", [{"class", "coelho-attachment"}], [body, caption])
  end

  @doc false
  def attachment_text(node) do
    case attr(node, "caption", nil) || attr(node, "filename", nil) do
      nil -> []
      text -> [text, "\n"]
    end
  end

  defp image?(content_type) when is_binary(content_type),
    do: String.starts_with?(content_type, "image/")

  defp image?(_content_type), do: false

  defp escape(value) when is_binary(value), do: Coelho.Render.escape(value)
  defp escape(value), do: Coelho.Render.escape(to_string(value))

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
