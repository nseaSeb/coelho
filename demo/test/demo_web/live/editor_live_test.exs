defmodule DemoWeb.EditorLiveTest do
  use DemoWeb.ConnCase

  import Phoenix.LiveViewTest

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
      |> element("form")
      |> render_change(%{"post" => %{"title" => "t", "body" => JSON.encode!(document)}})

    assert html =~ "typed by hand"
    assert html =~ "&lt;p&gt;typed by hand&lt;/p&gt;"
  end

  test "a document outside the schema is reported rather than stored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    hostile = JSON.encode!(%{"type" => "doc", "content" => [%{"type" => "script"}]})

    html =
      view
      |> element("form")
      |> render_change(%{"post" => %{"title" => "t", "body" => hostile}})

    assert html =~ "unknown node type"
  end

  test "a missing title is reported too", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = view |> element("form") |> render_change(%{"post" => %{"title" => ""}})

    assert html =~ "can&#39;t be blank"
  end

  test "saving a valid document says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    document = JSON.encode!(Coelho.empty())

    html =
      view |> element("form") |> render_submit(%{"post" => %{"title" => "t", "body" => document}})

    assert html =~ "exactly what would be written"
  end
end
