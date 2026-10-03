defmodule Coelho.UntrustedSchemaPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Coelho.{Document, Render, Schema}

  # The promise of `policy: :untrusted` is about every schema an application
  # can build, not about the shipped one, so the schema is what is generated
  # here: a block node, an inline node and a mark, each with any combination
  # of the four render fields, a URL attribute or not, and possibly a second
  # `extend/2` redeclaring some of those fields over the first.
  #
  # Two invariants, checked on the parsed output rather than on a regex:
  #
  #   * nothing in either render points anywhere — no element that loads or
  #     navigates, no attribute that does, no `url(`, and not one byte of
  #     the URL the document or the resolver holds
  #   * the inline render holds phrasing content only, given that the
  #     application's own inline forms do

  @evil "evil.example"
  @context %{resolve: &__MODULE__.resolve/1}

  def resolve(_key), do: "https://#{@evil}/file"

  @reference_tags ~w(a area base embed form frame iframe img image input link meta object
                     picture portal script source style svg track audio video
                     button select textarea option plaintext xmp listing noembed noframes
                     noscript template title)
  @reference_attrs ~w(href src srcset action formaction poster cite data background
                      longdesc ping manifest codebase archive usemap profile lowsrc dynsrc
                      icon xlink:href xml:base)
  @phrasing ~w(a abbr b bdi bdo br cite code data dfn em i img kbd mark q s samp small span
               strong sub sup time u var wbr)

  # -- What a render can be ---------------------------------------------------

  def fun_link(node, inner), do: Render.tag("a", [{"href", url(node)}], inner)
  def fun_img(node, _inner), do: Render.void_tag("img", [{"src", url(node)}])
  def fun_div(_node, inner), do: Render.tag("div", [{"data-x", "1"}], inner)
  def fun_span(_node, inner), do: Render.tag("span", [{"class", "f"}], inner)
  def fun_text(_node, inner), do: ["[", inner, "]"]

  def attrs_url(node), do: [{"href", url(node)}, {"src", url(node)}, {"class", "c"}]

  def attrs_style(_node),
    do: [{"style", "background:URL(https://#{@evil}/bg)"}, {"title", "t"}]

  # CSS unescapes an identifier before asking whether it is `url`, so no
  # substring check on the value can be the boundary.
  def attrs_escaped(_node),
    do: [{"style", "background:u\\rl(https://#{@evil}/bg)"}, {"data-x", "1"}]

  # A name nothing in the HTML standard fetches through, which Phoenix's own
  # `phoenix_html.js`, htmx and lazy loaders all do.
  def attrs_data(node),
    do: [{"data-to", url(node)}, {"data-method", "delete"}, {"data-src", url(node)}]

  def safe_block(_node, inner), do: Render.tag("div", [{"class", "u"}], inner)
  def safe_span(_node, inner), do: Render.tag("span", [{"class", "u"}], inner)

  defp url(node) do
    case Render.attr(node, "u") do
      url when is_binary(url) -> url
      _ -> "https://#{@evil}/fallback"
    end
  end

  defp element(tags) do
    gen all(
          tag <- member_of(tags),
          attrs <-
            member_of([
              [],
              [{"href", "https://#{@evil}/static"}],
              [{"SRC", "https://#{@evil}/static"}, {"class", "k"}],
              &__MODULE__.attrs_url/1,
              &__MODULE__.attrs_style/1,
              &__MODULE__.attrs_escaped/1,
              &__MODULE__.attrs_data/1
            ])
        ) do
      {tag, attrs}
    end
  end

  # A page form for a block node: anything at all.
  defp block_render do
    one_of([
      constant(nil),
      element(~w(div p section aside a iframe IFRAME Img form meta video span button plaintext)),
      member_of([
        &__MODULE__.fun_link/2,
        &__MODULE__.fun_img/2,
        &__MODULE__.fun_div/2,
        &__MODULE__.fun_span/2,
        &__MODULE__.fun_text/2
      ])
    ])
  end

  # Anything that will stand where only inline elements are legal: the
  # application's trusted inline forms can point anywhere, but they are
  # phrasing, or the inline renderer could not keep its promise even trusted.
  defp inline_render do
    one_of([
      constant(nil),
      element(~w(span em a A img q)),
      member_of([
        &__MODULE__.fun_link/2,
        &__MODULE__.fun_img/2,
        &__MODULE__.fun_span/2,
        &__MODULE__.fun_text/2
      ])
    ])
  end

  defp node_decl(inline?) do
    gen all(
          url? <- boolean(),
          url_validator <- member_of([:safe_url, {:nullable, :safe_url}]),
          void? <- boolean(),
          render_inline <- inline_render(),
          # An inline node whose inline form is its own may draw anything on
          # the page; one without has only its `:render` to stand inline.
          render <-
            if(inline? and is_nil(render_inline), do: inline_render(), else: block_render()),
          render_untrusted <-
            member_of([
              nil,
              if(inline?, do: &__MODULE__.safe_span/2, else: &__MODULE__.safe_block/2)
            ]),
          render_untrusted_inline <- member_of([nil, &__MODULE__.safe_span/2])
        ) do
      attrs =
        [k: [default: "k", validate: :string]] ++
          if(url?, do: [u: [default: nil, validate: url_validator]], else: [])

      [
        group: if(inline?, do: "inline", else: "block"),
        inline: inline?,
        void: void?,
        content: unless(void?, do: if(inline?, do: "text*", else: "inline*")),
        attrs: attrs,
        render: render,
        render_inline: render_inline,
        render_untrusted: render_untrusted,
        render_untrusted_inline: render_untrusted_inline
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp mark_decl do
    gen all(
          url? <- boolean(),
          render <-
            one_of([
              constant(nil),
              element(~w(span em a q)),
              member_of([&__MODULE__.fun_link/2, &__MODULE__.fun_span/2])
            ]),
          render_untrusted <- member_of([nil, &__MODULE__.safe_span/2])
        ) do
      attrs = if url?, do: [u: [default: nil, validate: {:nullable, :safe_url}]], else: []

      [attrs: attrs, render: render, render_untrusted: render_untrusted]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  # Some of the render fields of one node, redeclared over the first schema —
  # including back to `nil`, which `extend/2` honours.
  defp redeclaration do
    gen all(
          target <- member_of([:gx_block, :gx_inline]),
          keys <- list_of(member_of(~w(render_untrusted render_untrusted_inline)a), max_length: 2),
          values <- list_of(member_of([nil, &__MODULE__.safe_span/2]), length: 2)
        ) do
      {target, keys |> Enum.uniq() |> Enum.zip(values)}
    end
  end

  defp schema do
    gen all(
          block <- node_decl(false),
          inline <- node_decl(true),
          mark <- mark_decl(),
          redeclare <- one_of([constant(nil), redeclaration()])
        ) do
      build(block, inline, mark, redeclare)
    end
  end

  defp build(block, inline, mark, redeclare) do
    schema =
      Schema.extend(Schema.default(),
        nodes: [gx_block: block, gx_inline: inline],
        marks: [gx_mark: mark]
      )

    case redeclare do
      nil ->
        {:ok, schema}

      {_target, []} ->
        {:ok, schema}

      {target, fields} ->
        {:ok, Schema.extend(schema, nodes: [{target, fields}])}
    end
  end

  defp document(schema) do
    evil = "https://#{@evil}/doc"
    attrs = fn name -> with_url(%{"k" => "k"}, schema.nodes[name], evil) end

    inline =
      if schema.nodes.gx_inline.void,
        do: %{"type" => "gx_inline", "attrs" => attrs.(:gx_inline)},
        else: %{"type" => "gx_inline", "attrs" => attrs.(:gx_inline), "content" => [text("in")]}

    block =
      if schema.nodes.gx_block.void,
        do: %{"type" => "gx_block", "attrs" => attrs.(:gx_block)},
        else: %{
          "type" => "gx_block",
          "attrs" => attrs.(:gx_block),
          "content" => [text("b"), inline]
        }

    marked =
      Map.put(text("marked"), "marks", [
        %{"type" => "gx_mark", "attrs" => with_url(%{}, schema.marks.gx_mark, evil)}
      ])

    %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [text("p "), marked, inline]},
        block,
        %{
          "type" => "attachment",
          "attrs" => %{"key" => "k1", "filename" => "f.png", "content_type" => "image/png"}
        },
        %{"type" => "paragraph", "content" => [%{"type" => "image", "attrs" => %{"src" => evil}}]}
      ]
    }
  end

  defp with_url(attrs, spec, url),
    do: if(Map.has_key?(spec.attrs, :u), do: Map.put(attrs, "u", url), else: attrs)

  defp text(text), do: %{"type" => "text", "text" => text}

  defp elements(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("*")
  end

  defp assert_points_nowhere(html) do
    refute html =~ @evil, "the output carries the URL: #{html}"

    for {tag, attrs, _children} <- elements(html) do
      refute tag in @reference_tags, "<#{tag}> in #{html}"

      for {name, value} <- attrs do
        refute name in @reference_attrs, "#{name}= in #{html}"
        refute String.downcase(value) =~ "url(", "url( in #{html}"
      end
    end
  end

  property "an untrusted render of any schema points nowhere, and inline stays inline" do
    check all(built <- schema(), max_runs: 1000) do
      with {:ok, schema} <- built do
        {:ok, document} = Document.validate(document(schema), schema)

        # The premise: trusted, the same document does point somewhere.
        assert Render.to_html(document, schema, context: @context) =~ @evil

        page = Render.to_html(document, schema, context: @context, policy: :untrusted)
        inline = Render.to_inline_html(document, schema, context: @context, policy: :untrusted)

        assert_points_nowhere(page)
        assert_points_nowhere(inline)

        for {tag, _attrs, _children} <- elements(inline) do
          assert tag in @phrasing, "<#{tag}> in inline output #{inline}"
        end
      end
    end
  end
end
