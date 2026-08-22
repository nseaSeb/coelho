defmodule Coelho.IconsTest do
  use ExUnit.Case, async: true

  alias Coelho.Icons

  describe "icon/1" do
    test "draws every command the shipped toolbar can carry" do
      # A button with no icon falls back to its label, which is legible but
      # is not what the rest of the bar looks like. The commands the library
      # itself knows about are the ones that must not do that.
      supported =
        Coelho.LiveView.node_commands() ++
          ~w(bold italic strike code link caption undo redo) ++
          Enum.map(~w(left center right justify), &("align_" <> &1))

      for command <- supported do
        assert Icons.icon(command), "no icon for #{command}"
      end
    end

    test "answers nothing for a command it does not know" do
      # A mark an application added, which then shows its label as text.
      refute Icons.icon("highlight")
      refute Icons.icon(:bold)
    end

    test "is safe markup, so it is rendered rather than escaped" do
      assert {:safe, iodata} = Icons.icon("bold")
      svg = IO.iodata_to_binary(iodata)

      assert svg =~ ~s(<svg class="coelho-icon")
      assert svg =~ ~s(stroke="currentColor")
      # Hidden from a screen reader: the button's own aria-label is what
      # names it, and an icon announced beside it would say it twice.
      assert svg =~ ~s(aria-hidden="true")
      assert String.ends_with?(svg, "</svg>")
    end

    test "takes its size from a custom property, so an application can change it" do
      # Rather than a width and a height baked into every drawing.
      css = File.read!(Path.expand("../../assets/css/coelho.css", __DIR__))

      assert css =~ "--coelho-icon:"
      assert css =~ "width: var(--coelho-icon)"
      svg = IO.iodata_to_binary(elem(Icons.icon("bold"), 1))

      refute svg =~ ~r/<svg[^>]*\swidth=/
      refute svg =~ ~r/<svg[^>]*\sheight=/
    end
  end

  describe "label/1" do
    test "is English for what the library draws" do
      assert Icons.label("bullet_list") == "Bulleted list"
      assert Icons.label("align_center") == "Center"
    end

    test "and the command's own name for anything else" do
      assert Icons.label("highlight") == "highlight"
    end

    test "names every command it draws" do
      # An icon with no words is a button whose tooltip says `align_justify`.
      for command <- Icons.commands() do
        refute Icons.label(command) == command, "no English label for #{command}"
      end
    end
  end
end
