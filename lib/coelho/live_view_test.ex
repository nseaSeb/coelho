if Code.ensure_loaded?(Phoenix.LiveViewTest) do
  defmodule Coelho.LiveViewTest do
    @moduledoc """
    Driving and reading the editor from a LiveView test.

    The editor's container carries `phx-update="ignore"` — ProseMirror owns
    that subtree — so it is invisible to `render_change/2`: there is no input
    to fill and no text to assert on. What the server sees is the hidden
    input the hook writes the document into, and a test has to write it
    itself.

    Doing that by hand is three lines of JSON encoding and parameter nesting
    at every call site, and getting the nesting wrong fails as "the form
    ignored the change" rather than as a mistake. This is those three lines.

        import Coelho.LiveViewTest

        test "the intro is saved", %{conn: conn} do
          {:ok, view, _html} = live(conn, ~p"/portal/edit")

          type(view, "page[intro_doc]", paragraph("bonjour"))

          assert document(view, "page[intro_doc]") == paragraph("bonjour")
        end

    Nothing here needs the browser: it writes what the hook would have
    written, and reads what the server rendered back.
    """

    @doc """
    Posts a document as the editor would, and returns the rendered result.

    `name` is the hidden input's name — `"page[intro_doc]"` — or the
    `%Phoenix.HTML.FormField{}` it was rendered from. The document is encoded
    and nested into parameters the same way a browser would nest them.

    ## Options

      * `:event` — the `phx-change` event to send, `"validate"` by default
      * `:form` — a selector, to go through the form rather than through the
        event. Use this when the change has to carry the form's other fields:
        `form: "#page-form"`
      * `:params` — extra parameters merged in, for a change the application
        expects to arrive with company

    """
    @spec type(term(), name(), map(), keyword()) :: String.t()
    def type(view, name, document, opts \\ []) when is_map(document) do
      params = params(name, document, Keyword.get(opts, :params, %{}))

      case Keyword.fetch(opts, :form) do
        {:ok, selector} ->
          view
          |> Phoenix.LiveViewTest.form(selector, params)
          |> Phoenix.LiveViewTest.render_change()

        :error ->
          Phoenix.LiveViewTest.render_change(view, Keyword.get(opts, :event, "validate"), params)
      end
    end

    @doc """
    The document an editor is currently holding, decoded.

    Read off the hidden input the server rendered, which is where the
    editor's state is visible from Elixir. Returns `nil` when there is no
    such input, and the raw string when it does not hold a document — which
    is what a rejected document comes back as, so that the writer can fix it
    rather than lose it.
    """
    @spec document(term(), name()) :: map() | String.t() | nil
    def document(view_or_html, name) do
      case value_of(view_or_html, to_name(name)) do
        nil ->
          nil

        value ->
          case JSON.decode(value) do
            {:ok, document} -> document
            {:error, _reason} -> value
          end
      end
    end

    @doc """
    The parameters a change carrying this document would arrive with.

    `type/4` sends these; this is for a test that has its own way of sending —
    a `render_submit`, a `render_hook`, a controller `post`. The nesting is
    the browser's: `page[intro_doc]` becomes
    `%{"page" => %{"intro_doc" => json}}`, which is what `Plug.Conn.Query`
    reads back and what a form expects to see.

        params("page[intro_doc]", document, %{"page" => %{"title" => "Été"}})
        #=> %{"page" => %{"intro_doc" => "{…}", "title" => "Été"}}

    """
    @spec params(name(), map(), map()) :: map()
    def params(name, document, extra \\ %{}) when is_map(document) and is_map(extra) do
      name
      |> to_name()
      |> nest(JSON.encode!(document))
      |> deep_merge(extra)
    end

    @typedoc "A hidden input's name, or the form field it was rendered from."
    @type name :: String.t() | struct()

    defp to_name(%Phoenix.HTML.FormField{name: name}), do: name
    defp to_name(name) when is_binary(name), do: name

    # `page[intro_doc]` is `%{"page" => %{"intro_doc" => value}}`, the way a
    # browser posts it and `Plug.Conn.Query` reads it back.
    defp nest(name, value), do: name |> segments() |> build(value)

    defp build([last], value), do: %{last => value}
    defp build([first | rest], value), do: %{first => build(rest, value)}

    defp segments(name) do
      case String.split(name, ["[", "]"], trim: true) do
        [] -> raise ArgumentError, "#{inspect(name)} is not an input name"
        segments -> segments
      end
    end

    defp deep_merge(left, right) when is_map(left) and is_map(right) do
      Map.merge(left, right, fn _key, a, b -> deep_merge(a, b) end)
    end

    defp deep_merge(_left, right), do: right

    # The value is read out of the rendered attribute rather than through a
    # parser, so this needs no HTML dependency of its own. Phoenix escapes
    # exactly five characters on the way in, and this puts back exactly those.
    defp value_of(html, name) when is_binary(html) do
      pattern = ~r/<input[^>]*name="#{Regex.escape(name)}"[^>]*value="([^"]*)"/

      case Regex.run(pattern, html) do
        [_match, value] -> unescape(value)
        nil -> nil
      end
    end

    defp value_of(view, name), do: view |> Phoenix.LiveViewTest.render() |> value_of(name)

    defp unescape(value) do
      value
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")
    end
  end
end
