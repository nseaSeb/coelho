defmodule Coelho.Plug.AttachmentsTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Coelho.{Attachments, Storage}
  alias Coelho.Plug.Attachments, as: Plugged
  alias Coelho.Storage.Disk

  @moduletag :tmp_dir
  @secret :crypto.strong_rand_bytes(32)

  def secret, do: @secret

  def metadata("image"), do: %{content_type: "image/png", filename: "a.png"}
  def metadata("svg"), do: %{content_type: "image/svg+xml", filename: "a.svg"}
  def metadata("html"), do: %{content_type: "text/html", filename: ~s(ev"il name.html)}
  def metadata(_key), do: nil

  setup %{tmp_dir: tmp_dir} do
    storage = Disk.new(tmp_dir)

    options =
      Plugged.init(
        at: "/attachments",
        storage: storage,
        secret: {__MODULE__, :secret, []},
        metadata: {__MODULE__, :metadata, []}
      )

    %{storage: storage, options: options}
  end

  defp get(url, options), do: :get |> conn(url) |> Plugged.call(options)

  defp signed(key, opts \\ []), do: Attachments.signed_url("/attachments", key, @secret, opts)

  defp store(storage, key, body \\ "bytes") do
    :ok = Storage.put(storage, key, {:binary, body})
    key
  end

  describe "serving" do
    test "serves a stored file to a signed request", %{storage: storage, options: options} do
      key = store(storage, "image", "png bytes")

      conn = get(signed(key), options)

      assert conn.status == 200
      assert conn.halted
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/png"
      assert get_resp_header(conn, "content-disposition") == ["inline"]
    end

    test "404 when the key is signed but nothing is stored", %{options: options} do
      assert %{status: 404} = get(signed("image"), options)
    end

    test "a request outside the mount point falls through", %{options: options} do
      conn = get("/elsewhere/image", options)

      refute conn.halted
      assert conn.status == nil
    end

    test "a key nested below the mount point falls through", %{options: options} do
      refute get("/attachments/deeper/image", options).halted
    end
  end

  describe "signatures" do
    test "an unsigned request is refused", %{storage: storage, options: options} do
      store(storage, "image")

      assert %{status: 403} = get("/attachments/image", options)
    end

    test "a tampered signature is refused", %{storage: storage, options: options} do
      store(storage, "image")

      assert %{status: 403} = get("/attachments/image?expires=99999999999&signature=x", options)
    end

    test "an expired signature is refused, and says so", %{storage: storage, options: options} do
      store(storage, "image")

      assert %{status: 410} = get(signed("image", expires_in: 60, now: 1000), options)
    end

    test "a key shaped to escape the root is refused", %{options: options} do
      assert %{status: 403} = get("/attachments/..?expires=1&signature=x", options)
    end
  end

  describe "serving other people's files" do
    test "SVG is sent as a download, not rendered", %{storage: storage, options: options} do
      store(storage, "svg", "<svg><script>alert(1)</script></svg>")

      assert [disposition] = get_resp_header(get(signed("svg"), options), "content-disposition")
      assert disposition =~ "attachment"
      refute disposition =~ "inline"
    end

    test "anything not a safe image type is a download", %{storage: storage, options: options} do
      store(storage, "html", "<script>alert(1)</script>")

      assert [disposition] = get_resp_header(get(signed("html"), options), "content-disposition")
      assert disposition =~ "attachment"
    end

    test "the filename cannot break out of the header", %{storage: storage, options: options} do
      store(storage, "html")

      assert [disposition] = get_resp_header(get(signed("html"), options), "content-disposition")
      assert disposition == ~s(attachment; filename="evil name.html")
    end

    test "an unknown key gets no content type of its own", %{storage: storage, options: options} do
      key = store(storage, Coelho.Attachment.generate_key())

      assert [content_type] = get_resp_header(get(signed(key), options), "content-type")
      assert content_type =~ "application/octet-stream"
    end
  end
end
