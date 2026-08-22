defmodule DemoWeb.EditorLiveTest do
  use DemoWeb.ConnCase

  import Phoenix.LiveViewTest
  import Coelho.LiveViewTest

  test "renders the editor and every server-side derivation of the document", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Structured rich text for Phoenix"
    assert html =~ ~s(phx-hook="Coelho")
    assert html =~ "What is stored"
    assert html =~ "What full text search would index"
  end

  test "an attachment URL is resolved at render time, not stored", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # The stored document carries the key; only the rendered HTML carries a URL.
    assert html =~ "sample-key"
    assert html =~ "expires="
    refute html =~ "&quot;url&quot;"
  end

  test "editing the document updates what the server would store and index", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    document = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "typed by hand"}]}
      ]
    }

    html =
      view
      |> element("#post-form")
      |> render_change(%{"post" => %{"title" => "t", "body" => JSON.encode!(document)}})

    assert html =~ "typed by hand"
    assert html =~ "&lt;p&gt;typed by hand&lt;/p&gt;"
  end

  test "an edit driven through the helper the library ships", %{conn: conn} do
    # `Coelho.LiveViewTest` exists so an application does not write the three
    # lines above at every call site — JSON encoding, parameter nesting, and
    # the form selector. Nothing used it, which for a module we hand people
    # to write *their* tests with is the wrong way round.
    {:ok, view, _html} = live(conn, "/")

    document = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "text" => "through the helper"}]
        }
      ]
    }

    # The other fields ride along in `:params`, nested the way the form nests
    # them — `%{"title" => …}` at the top level never reaches
    # `handle_event("validate", %{"post" => params}, …)` and the changeset
    # then falls back to what it already held, which is a test passing for
    # the wrong reason.
    html =
      type(view, "post[body]", document, params: %{"post" => %{"title" => "given by the test"}})

    assert html =~ "through the helper"
    assert html =~ "given by the test"

    # And read back the way an application asserts on what the server holds:
    # normalised, so it is the document the server would store rather than
    # the bytes the browser happened to send.
    assert document(view, "post[body]") == document
  end

  test "a document outside the schema is reported rather than stored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    hostile = JSON.encode!(%{"type" => "doc", "content" => [%{"type" => "script"}]})

    html =
      view
      |> element("#post-form")
      |> render_change(%{"post" => %{"title" => "t", "body" => hostile}})

    assert html =~ "unknown node type"
  end

  test "a missing title is reported too", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = view |> element("#post-form") |> render_change(%{"post" => %{"title" => ""}})

    assert html =~ "can&#39;t be blank"
  end

  test "saving a valid document says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    document = JSON.encode!(Coelho.empty())

    html =
      view
      |> element("#post-form")
      |> render_submit(%{"post" => %{"title" => "t", "body" => document}})

    assert html =~ "exactly what would be written"
  end

  describe "attachments" do
    @png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "not really a png"

    test "an upload is stored and comes back through a signed URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> file_input("#post-form", :attachment, [
        %{name: "photo.png", content: @png, type: "image/png"}
      ])
      |> render_upload("photo.png")

      # The node carries a key; the URL is separate, and only a preview.
      assert_push_event(view, "coelho:insert", %{node: node, preview: url})
      assert %{"type" => "attachment", "attrs" => %{"key" => key}} = node
      assert node["attrs"]["filename"] == "photo.png"
      refute Map.has_key?(node["attrs"], "url")

      assert %URI{path: "/attachments/" <> ^key} = URI.parse(url)

      served = get(build_conn(), url)

      assert served.status == 200
      assert served.resp_body == @png
      assert ["nosniff"] = Plug.Conn.get_resp_header(served, "x-content-type-options")
      assert ["inline"] = Plug.Conn.get_resp_header(served, "content-disposition")
    end

    test "the same bytes are refused without a signature", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> file_input("#post-form", :attachment, [
        %{name: "p.png", content: @png, type: "image/png"}
      ])
      |> render_upload("p.png")

      assert_push_event(view, "coelho:insert", %{preview: url})
      %URI{path: path} = URI.parse(url)

      assert get(build_conn(), path).status == 403
    end
  end
end
