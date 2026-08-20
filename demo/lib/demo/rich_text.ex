defmodule Demo.RichText do
  @moduledoc """
  The application's own schema: the default one, plus a mention.

  This is the extension path in full. A mention is a node like any other —
  it is declared once here, validated by the same rules as a paragraph,
  rendered by the server, and taught to the browser through
  `createCoelhoHook` in `assets/js/app.js`.

  The schema lives in a module attribute, so it is built once at compile
  time. That works because every term in it is escapable: the render
  functions below are named, not closures.
  """

  @schema Coelho.Schema.extend(Coelho.Schema.default(),
            nodes: [
              mention: [
                group: "inline",
                inline: true,
                void: true,
                attrs: [
                  user_id: [required: true, validate: :integer],
                  label: [default: nil, validate: {:nullable, :string}]
                ],
                render: &__MODULE__.render_mention/2,
                to_text: &__MODULE__.mention_text/1,
                parse: [{"span", &__MODULE__.parse_mention/1}]
              ]
            ]
          )

  def schema, do: @schema

  @doc """
  A mention is inert markup, not a link: what it points at is an id, and
  what that becomes is the application's business at render time.
  """
  def render_mention(node, _inner) do
    Coelho.Render.tag(
      "span",
      [{"class", "mention"}, {"data-user-id", attr(node, "user_id")}],
      Coelho.Render.escape(label(node))
    )
  end

  def mention_text(node), do: label(node)

  @doc """
  Imports `<span data-user-id="7">` and leaves every other span alone.

  A parse rule matches on the tag, and then on whether the attributes it
  extracts satisfy the schema: no `user_id`, no match, so the span falls
  through to the transparent rule and keeps its text.
  """
  def parse_mention(attrs) do
    case attrs |> Map.get("data-user-id", "") |> Integer.parse() do
      {user_id, ""} -> %{"user_id" => user_id}
      _ -> %{}
    end
  end

  defp label(node), do: attr(node, "label") || "@#{attr(node, "user_id")}"

  defp attr(node, name), do: node |> Map.get("attrs", %{}) |> Map.get(name)
end
