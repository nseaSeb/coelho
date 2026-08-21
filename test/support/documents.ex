defmodule Coelho.Test.Documents do
  @moduledoc false
  # Generators for documents the shipped schema accepts. Shared, because two
  # properties asking different questions of the same shapes should be asking
  # them of the *same* shapes — a generator copied is a generator that drifts.

  use ExUnitProperties

  @doc """
  A document the shipped schema accepts.

  `exclude` drops node types from what is drawn, for a property whose premise
  does not hold for all of them. Text extraction is the case: a node with a
  `:to_text` in its spec contributes something the document does not hold as
  a text node, which is exactly what that field is for.
  """
  def document(exclude \\ []) do
    gen all(content <- list_of(block(exclude), min_length: 1, max_length: 5)) do
      %{"type" => "doc", "content" => content}
    end
  end

  def block(exclude \\ []) do
    [
      paragraph:
        gen(
          all(content <- list_of(inline(), max_length: 4)) do
            %{"type" => "paragraph", "content" => content}
          end
        ),
      heading:
        gen(
          all(level <- integer(1..6), content <- list_of(text_node(), max_length: 3)) do
            %{"type" => "heading", "attrs" => %{"level" => level}, "content" => content}
          end
        ),
      code_block:
        gen(
          all(content <- list_of(plain_text_node(), max_length: 3)) do
            %{"type" => "code_block", "content" => content}
          end
        ),
      bullet_list:
        gen(
          all(item <- list_of(inline(), max_length: 3)) do
            %{
              "type" => "bullet_list",
              "content" => [
                %{
                  "type" => "list_item",
                  "content" => [%{"type" => "paragraph", "content" => item}]
                }
              ]
            }
          end
        ),
      blockquote:
        gen(
          all(content <- list_of(inline(), max_length: 3)) do
            %{
              "type" => "blockquote",
              "content" => [%{"type" => "paragraph", "content" => content}]
            }
          end
        ),
      attachment:
        gen(
          all(name <- string(:alphanumeric, min_length: 1)) do
            %{"type" => "attachment", "attrs" => %{"key" => name, "filename" => name <> ".pdf"}}
          end
        ),
      horizontal_rule: constant(%{"type" => "horizontal_rule"})
    ]
    |> Enum.reject(fn {name, _generator} -> name in exclude end)
    |> Enum.map(&elem(&1, 1))
    |> one_of()
  end

  def inline do
    one_of([
      text_node(),
      constant(%{"type" => "hard_break"}),
      gen all(src <- string(:alphanumeric, min_length: 1)) do
        %{"type" => "image", "attrs" => %{"src" => "/" <> src <> ".png"}}
      end
    ])
  end

  # Not `uniq_list_of`: it gives up after ten consecutive duplicates, and
  # there are only five marks to draw from, so the run failed on the seeds
  # that happened to repeat — intermittently, and never where it was looked
  # for. Drawing a list and taking it apart cannot run out of tries.
  def text_node do
    gen all(
          text <- string(:printable, min_length: 1),
          drawn <- list_of(mark(), max_length: 3)
        ) do
      marks = Enum.uniq_by(drawn, & &1["type"])

      case marks do
        [] -> %{"type" => "text", "text" => text}
        marks -> %{"type" => "text", "text" => text, "marks" => marks}
      end
    end
  end

  def plain_text_node do
    gen all(text <- string(:printable, min_length: 1)) do
      %{"type" => "text", "text" => text}
    end
  end

  def mark do
    one_of([
      constant(%{"type" => "bold"}),
      constant(%{"type" => "italic"}),
      constant(%{"type" => "strike"}),
      constant(%{"type" => "code"}),
      gen all(path <- string(:alphanumeric, min_length: 1)) do
        %{"type" => "link", "attrs" => %{"href" => "/" <> path}}
      end
    ])
  end
end
