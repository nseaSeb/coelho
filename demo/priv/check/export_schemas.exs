# What the bridge check is fed. Written here rather than as three `mix run
# -e` lines, because the third schema is a declaration and not a one-liner:
# it is an application's, with marks the library has never heard of, which
# is the case the browser half has to survive without a line of JavaScript
# written for it.
[schema, document, extended] = System.argv()

File.write!(schema, JSON.encode!(Coelho.Schema.to_json(Coelho.Schema.default())))
File.write!(document, JSON.encode!(Coelho.empty()))

application =
  Coelho.Schema.extend(Coelho.Schema.default(),
    marks: [
      # Declared end to end in Elixir: the browser builds its toDOM and
      # parseDOM out of `:render` and `:parse`.
      highlight: [class: "hl", render: {"mark", [{"class", "base"}]}, parse: ["mark"]],
      # And one that says nothing about how it looks, which is the mark
      # that used to take the whole editor down with it.
      effect: [class: "rainbow"]
    ]
  )

File.write!(extended, JSON.encode!(Coelho.Schema.to_json(application)))
