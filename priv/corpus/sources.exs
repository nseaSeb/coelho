# The source documents of the corpus, and nothing else: what they normalise
# to, hash to and render as lives in the fixture, written by
# `mix run priv/corpus/write.exs` and read by `corpus_test.exs`.
#
# Each entry names the schema it is written against. What earns a place here
# is a shape whose *bytes* somebody downstream depends on — a hash stored as
# proof of acceptance, an ETag, a diff between two revisions — not another
# way of exercising the same rule.

text = fn text, marks -> %{"type" => "text", "text" => text, "marks" => marks} end
plain = fn value -> %{"type" => "text", "text" => value} end
doc = fn content -> %{"type" => "doc", "content" => content} end
paragraph = fn content -> %{"type" => "paragraph", "content" => content} end

[
  %{
    name: "a paragraph of plain text",
    schema: "default",
    document: doc.([paragraph.([plain.("The document is the storage.")])])
  },
  %{
    name: "marks in the order the editor happened to add them",
    schema: "default",
    document:
      doc.([
        paragraph.([
          text.("both", [%{"type" => "italic"}, %{"type" => "bold"}]),
          plain.(" and "),
          text.("one", [%{"type" => "bold"}])
        ])
      ])
  },
  %{
    name: "a heading at the level the schema calls default",
    schema: "default",
    document: doc.([%{"type" => "heading", "content" => [plain.("Title")]}])
  },
  %{
    name: "a heading that names its level",
    schema: "default",
    document:
      doc.([%{"type" => "heading", "attrs" => %{"level" => 3}, "content" => [plain.("Section")]}])
  },
  %{
    # The pair that has to move together: an attribute at its schema default
    # is dropped on the way in, so this entry says both what the default *is*
    # and that the renderer agrees with it. Change one without the other and
    # the canonical form here moves, which is the point.
    name: "a level written out, which the schema calls its default",
    schema: "default",
    document:
      doc.([%{"type" => "heading", "attrs" => %{"level" => 1}, "content" => [plain.("Title")]}])
  },
  %{
    name: "an alignment written as left, which is no alignment at all",
    schema: "default",
    document: doc.([Map.put(paragraph.([plain.("centred?")]), "attrs", %{"align" => "left"})])
  },
  %{
    name: "an alignment that is one",
    schema: "default",
    document: doc.([Map.put(paragraph.([plain.("centred")]), "attrs", %{"align" => "center"})])
  },
  %{
    name: "text a renderer must escape",
    schema: "default",
    document: doc.([paragraph.([plain.("< & > \" ' and <script>alert(1)</script>")])])
  },
  %{
    name: "a link, and an address a browser would execute",
    schema: "default",
    document:
      doc.([
        paragraph.([
          text.("safe", [
            %{"type" => "link", "attrs" => %{"href" => "https://example.test/a?b=1&c=2"}}
          ])
        ])
      ])
  },
  %{
    name: "characters that are one grapheme made of several code points",
    schema: "default",
    document: doc.([paragraph.([plain.("famille 👨‍👩‍👧 drapeau 🇫🇷 accent é")])])
  },
  %{
    name: "a list holding blocks",
    schema: "default",
    document:
      doc.([
        %{
          "type" => "bullet_list",
          "content" => [
            %{"type" => "list_item", "content" => [paragraph.([plain.("one")])]},
            %{"type" => "list_item", "content" => [paragraph.([plain.("two")])]}
          ]
        }
      ])
  },
  %{
    name: "a code block, where whitespace is content",
    schema: "default",
    document:
      doc.([%{"type" => "code_block", "content" => [plain.("  if a < b do\n    :ok\n  end")]}])
  },
  %{
    name: "an attachment, whose URL is resolved and never stored",
    schema: "default",
    document:
      doc.([
        %{
          "type" => "attachment",
          "attrs" => %{
            "key" => "kept",
            "filename" => "dot.png",
            "content_type" => "image/png",
            "byte_size" => 70,
            "caption" => "A dot"
          }
        }
      ])
  },
  %{
    name: "what an application added: a mark, a void node and a block of its own",
    schema: "extended",
    document:
      doc.([
        %{
          "type" => "callout",
          "content" => [
            paragraph.([
              plain.("Invoice "),
              %{
                "type" => "variable",
                "attrs" => %{"name" => "number", "label" => "{{number}}"}
              },
              plain.(" for "),
              text.("you", [%{"type" => "highlight"}])
            ])
          ]
        }
      ])
  },
  %{
    name: "a hard break and a horizontal rule",
    schema: "default",
    document:
      doc.([
        paragraph.([plain.("before"), %{"type" => "hard_break"}, plain.("after")]),
        %{"type" => "horizontal_rule"}
      ])
  }
]
