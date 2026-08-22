defmodule Coelho.Icons do
  @moduledoc """
  The toolbar's icons.

  One line drawing per command, written for this library rather than taken
  from an icon set: nothing to attribute, nothing to keep up with, and no
  second visual identity arriving with the dependency.

  Each is a 24-grid `<svg>` stroked in `currentColor`, so it takes the colour
  of the button it sits in — including the pressed and disabled states the
  stylesheet already draws. Its size is the `--coelho-icon` custom property,
  `20px` by default:

      .coelho { --coelho-icon: 24px; }

  An application replaces one, or all of them, through the editor's `:icons`
  attribute — see `Coelho.LiveView.coelho_editor/1`. What it passes has to be
  safe markup already, since it is rendered rather than escaped: markup is
  what an application states, never what it happens to hold.

  A command with no icon here falls back to its label as text, which is what
  a command an application added does until it is given one.

  A heading naming its level — `heading_3`, beside `heading` — is deliberately
  one of those: six drawings of an H differing by a numeral are six buttons
  nobody can tell apart at 20px, where "Heading 3" is read at a glance. An
  application that wants a drawing there passes its own through `:icons`.
  """

  @stroke ~s(viewBox="0 0 24 24" fill="none" stroke="currentColor" ) <>
            ~s(stroke-width="2" stroke-linecap="round" stroke-linejoin="round")

  # The letterforms are drawn rather than set in type: a `<text>` element
  # would take the reader's font, which is the one thing about an icon that
  # must not vary.
  @paths %{
    # A stem with two bowls.
    "bold" => ["M8 5v14", "M8 5h4.5a3.5 3.5 0 0 1 0 7H8", "M8 12h5a3.5 3.5 0 0 1 0 7H8"],
    # Serifs top and bottom, and the slant between them.
    "italic" => ["M10 5h8", "M6 19h8", "M15 5l-6 14"],
    # An S drawn as two bowls, and the line struck through it.
    "strike" => ["M16 5h-6a3.5 3.5 0 0 0 0 7h4a3.5 3.5 0 0 1 0 7H8", "M4 12h16"],
    # Two chevrons, pointing away from what they enclose.
    "code" => ["m9 8-4 4 4 4", "M15 8l4 4-4 4"],
    # Two links of a chain, each reaching into the other.
    "link" => [
      "M10 13a5 5 0 0 0 7 0l2-2a5 5 0 0 0-7-7l-1 1",
      "M14 11a5 5 0 0 0-7 0l-2 2a5 5 0 0 0 7 7l1-1"
    ],
    "heading" => ["M6 5v14", "M18 5v14", "M6 12h12"],
    # A pilcrow: the bowl, its stem, and the stem beside it.
    "paragraph" => ["M17 5h-6a4 4 0 0 0 0 8h2", "M13 5v14", "M17 5v14"],
    # The chevrons of `code`, in a frame.
    "code_block" => ["M4 5h16v14H4z", "m10 11-2 2 2 2", "M14 11l2 2-2 2"],
    # Two quotation marks, as four ticks. Drawn as closed curls they blot
    # over at this size; a bar with lines beside it, the other common
    # drawing, is the alignment icons over again.
    "blockquote" => ["M6 8 4.5 13", "M9.5 8 8 13", "M16 8l-1.5 5", "M19.5 8L18 13"],
    # Round caps turn the marker segments into dots.
    "bullet_list" => [
      "M4.5 6h.01",
      "M4.5 12h.01",
      "M4.5 18h.01",
      "M9 6h11",
      "M9 12h11",
      "M9 18h11"
    ],
    # The same lines, numbered. The digits are strokes rather than type, and
    # thinner than the rest: a stroke of 2 on a glyph 5 high is half the
    # glyph, and every counter in it closes up into a blot.
    "ordered_list" => [
      {"M2.6 4.3 4.4 3v5.4", ~s(stroke-width="1.3")},
      {"M2.4 4.2h4", ~s(stroke-width="1.3")},
      {"M2.4 10.6a1.8 1.8 0 0 1 3.6.4c0 1.3-3.6 2.2-3.6 3.4h3.9", ~s(stroke-width="1.3")},
      {"M2.4 17h3.7l-2 2.3h.4a1.6 1.6 0 1 1-1.6 2", ~s(stroke-width="1.3")},
      "M11 6h9",
      "M11 12h9",
      "M11 18h9"
    ],
    "horizontal_rule" => ["M4 12h16"],
    # An arrow turning back on itself.
    "undo" => ["m9 14-5-5 5-5", "M4 9h11a5 5 0 0 1 0 10h-4"],
    "redo" => ["m15 14 5-5-5-5", "M20 9H9a5 5 0 0 0 0 10h4"],
    # A picture, and the line of text under it. Without something inside,
    # the frame alone reads as a screen.
    "caption" => ["M4 4h16v11H4z", "m7 12 3-3 2.5 2.5L15 9l2 2", "M4 19h16"],
    "align_left" => ["M4 6h16", "M4 12h10", "M4 18h13"],
    "align_center" => ["M4 6h16", "M7 12h10", "M6 18h12"],
    "align_right" => ["M4 6h16", "M10 12h10", "M7 18h13"],
    "align_justify" => ["M4 6h16", "M4 12h16", "M4 18h16"]
  }

  @doc """
  The icon for a command, or `nil` where there is none.

  Safe markup, so it is rendered rather than escaped. Every path in it is a
  literal in this module: nothing reaches it from a document, a parameter or
  an application.
  """
  @spec icon(String.t()) :: {:safe, iodata()} | nil
  def icon(command) when is_binary(command) do
    case Map.fetch(@paths, command) do
      {:ok, paths} -> {:safe, svg(paths)}
      :error -> nil
    end
  end

  def icon(_command), do: nil

  @doc """
  The commands this module draws.
  """
  @spec commands() :: [String.t()]
  def commands, do: @paths |> Map.keys() |> Enum.sort()

  # English, like the field's own words, and for the same reason: a tooltip
  # reading `bullet_list` is worse than no tooltip, and an application with a
  # translator overrides these through `:labels`. A command with no entry
  # here answers to its own name, which is what one an application added
  # does until it is given a label.
  @labels %{
    "bold" => "Bold",
    "italic" => "Italic",
    "strike" => "Strikethrough",
    "code" => "Code",
    "link" => "Link",
    "heading" => "Heading",
    "paragraph" => "Paragraph",
    "code_block" => "Code block",
    "blockquote" => "Quote",
    "bullet_list" => "Bulleted list",
    "ordered_list" => "Numbered list",
    "horizontal_rule" => "Separator",
    "undo" => "Undo",
    "redo" => "Redo",
    "caption" => "Caption",
    "align_left" => "Align left",
    "align_center" => "Center",
    "align_right" => "Align right",
    "align_justify" => "Justify"
  }

  @doc """
  What a command is called in English, or its own name where nothing is.
  """
  @spec label(String.t()) :: String.t()
  def label("heading_" <> level) when level in ~w(1 2 3 4 5 6), do: "Heading " <> level
  def label(command) when is_binary(command), do: Map.get(@labels, command, command)

  defp svg(paths) do
    [
      ~s(<svg class="coelho-icon" ),
      @stroke,
      ~s( aria-hidden="true" focusable="false">),
      Enum.map(paths, &path/1),
      "</svg>"
    ]
  end

  # A path may carry attributes of its own, which is how the numerals of an
  # ordered list are stroked thinner than the lines beside them.
  defp path({d, attrs}), do: [~s(<path d="), d, ~s(" ), attrs, "/>"]
  defp path(d), do: [~s(<path d="), d, ~s("/>)]
end
