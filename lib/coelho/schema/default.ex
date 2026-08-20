defmodule Coelho.Schema.Default do
  @moduledoc """
  The schema Coelho ships with.

  It covers what an application typically needs out of the box — paragraphs,
  headings, lists, quotes, code blocks, images and the usual inline marks —
  and is meant to be copied and adapted rather than extended in place.

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
        paragraph: [content: "inline*", group: "block", render: {"p", []}],
        heading: [
          content: "inline*",
          group: "block",
          attrs: [level: [default: 1, validate: {:one_of, [1, 2, 3, 4, 5, 6]}]],
          render: &__MODULE__.render_heading/2
        ],
        blockquote: [content: "block+", group: "block", render: {"blockquote", []}],
        bullet_list: [content: "list_item+", group: "block", render: {"ul", []}],
        ordered_list: [
          content: "list_item+",
          group: "block",
          attrs: [start: [default: 1, validate: :integer]],
          render: {"ol", &__MODULE__.ordered_list_attrs/1}
        ],
        list_item: [content: "paragraph block*", render: {"li", []}],
        code_block: [
          content: "text*",
          group: "block",
          marks: :none,
          attrs: [language: [default: nil, validate: {:nullable, :string}]],
          render: &__MODULE__.render_code_block/2
        ],
        horizontal_rule: [group: "block", void: true, render: {"hr", []}],
        image: [
          group: "inline",
          inline: true,
          void: true,
          attrs: [
            src: [required: true, validate: :safe_url],
            alt: [default: nil, validate: {:nullable, :string}],
            title: [default: nil, validate: {:nullable, :string}]
          ],
          render: {"img", &__MODULE__.image_attrs/1}
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
          to_text: "\n"
        ],
        text: [group: "inline", inline: true, text: true]
      ],
      marks: [
        bold: [render: {"strong", []}],
        italic: [render: {"em", []}],
        strike: [render: {"s", []}],
        code: [render: {"code", []}],
        link: [
          attrs: [
            href: [required: true, validate: :safe_url],
            title: [default: nil, validate: {:nullable, :string}]
          ],
          render: {"a", &__MODULE__.link_attrs/1}
        ]
      ]
    )
  end

  @doc false
  def render_heading(node, inner) do
    Coelho.Render.tag("h" <> Integer.to_string(heading_level(node)), [], inner)
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

  defp attr(node, name, default) do
    node |> Map.get("attrs", %{}) |> Map.get(name, default)
  end
end
