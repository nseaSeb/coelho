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

  defmodule Presigned do
    @moduledoc "Object storage: it hands out a URL rather than the bytes."
    @behaviour Coelho.Storage

    defstruct []

    @impl true
    def put(_storage, _key, _source), do: :ok
    @impl true
    def read(_storage, _key), do: {:error, :enoent}
    @impl true
    def path(_storage, _key), do: :error
    @impl true
    def delete(_storage, _key), do: :ok
    @impl true
    def exists?(_storage, _key), do: true

    @impl true
    def redirect_url(_storage, key, opts) do
      {:ok,
       "https://bucket.example/#{key}?X-Expires=#{Keyword.fetch!(opts, :expires_in)}" <>
         "&type=#{Keyword.fetch!(opts, :content_type)}"}
    end
  end

  defmodule Remote do
    @moduledoc "A storage with no local path, the way object storage behaves."
    @behaviour Coelho.Storage

    defstruct files: %{}

    @impl true
    def put(_storage, _key, _source), do: {:error, :read_only}
    @impl true
    def path(_storage, _key), do: :error
    @impl true
    def delete(_storage, _key), do: :ok
    @impl true
    def exists?(storage, key), do: Map.has_key?(storage.files, key)

    @impl true
    def read(storage, key) do
      case Map.fetch(storage.files, key) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :enoent}
      end
    end
  end

  def metadata("image"), do: %{content_type: "image/png", filename: "a.png"}
  def metadata("svg"), do: %{content_type: "image/svg+xml", filename: "a.svg"}
  def metadata("html"), do: %{content_type: "text/html", filename: ~s(ev"il name.html)}
  def metadata("hostile"), do: %{content_type: "image/png\r\nx-injected: 1", filename: "a.png"}
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
      assert get_resp_header(conn, "content-type") == ["image/png"]
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

      assert get_resp_header(get(signed(key), options), "content-type") == [
               "application/octet-stream"
             ]
    end
  end

  describe "a storage with no local path" do
    setup do
      storage = %Remote{files: %{"image" => "remote bytes"}}

      %{
        options:
          Plugged.init(
            at: "/attachments",
            storage: storage,
            secret: {__MODULE__, :secret, []},
            metadata: {__MODULE__, :metadata, []}
          )
      }
    end

    test "is read rather than sent as a file", %{options: options} do
      conn = get(signed("image"), options)

      assert conn.status == 200
      assert conn.resp_body == "remote bytes"
      assert get_resp_header(conn, "content-disposition") == ["inline"]
    end

    test "a key it does not hold is a 404, not a 403", %{options: options} do
      assert %{status: 404} = get(signed("missing"), options)
    end
  end

  describe "responses that carry no body of their own" do
    test "an error response does not tell the browser to save it", %{options: options} do
      conn = get(signed("html"), options)

      assert conn.status == 404
      assert get_resp_header(conn, "content-disposition") == []
    end
  end

  describe "header values coming from the uploader" do
    test "a content type that is not a plain token is not passed on", %{
      storage: storage,
      options: options
    } do
      # A header value carrying CRLF raises inside Plug, turning every fetch
      # of that attachment into a 500.
      store(storage, "hostile")

      conn = get(signed("hostile"), options)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-injected") == []
    end

    test "an image is served as its own type, without a charset", %{
      storage: storage,
      options: options
    } do
      store(storage, "image")

      assert get_resp_header(get(signed("image"), options), "content-type") == ["image/png"]
    end
  end

  describe "query parameters that are not strings" do
    test "a list-valued expires is refused, not a crash", %{storage: storage, options: options} do
      store(storage, "image")

      assert %{status: 403} = get("/attachments/image?expires[]=1&signature=x", options)
      assert %{status: 403} = get("/attachments/image?expires[a]=1&signature=x", options)
      assert %{status: 403} = get("/attachments/image?expires=1&signature[]=x", options)
    end
  end

  describe "a storage that hands out its own URL" do
    setup do
      %{
        options:
          Plugged.init(
            at: "/attachments",
            storage: %Presigned{},
            secret: {__MODULE__, :secret, []},
            metadata: {__MODULE__, :metadata, []}
          )
      }
    end

    test "is redirected to rather than read through", %{options: options} do
      conn = get(signed("image"), options)

      assert conn.status == 302
      assert [location] = get_resp_header(conn, "location")
      assert location =~ "https://bucket.example/image"
      assert conn.resp_body == ""
    end

    test "the redirect outlives nothing the signature does not", %{options: options} do
      conn = get(signed("image", expires_in: 120), options)

      assert [location] = get_resp_header(conn, "location")
      assert [_, seconds] = Regex.run(~r/X-Expires=(\d+)/, location)
      # What is left of the signature, not what it started with.
      assert String.to_integer(seconds) in 118..120
    end

    test "the signature is still what decides", %{options: options} do
      assert %{status: 403} = get("/attachments/image", options)
      assert %{status: 410} = get(signed("image", expires_in: 60, now: 1000), options)
    end

    test "an expired signature leaves nothing to redirect to", %{options: options} do
      conn = get(signed("image", expires_in: 60, now: 1000), options)

      assert get_resp_header(conn, "location") == []
    end
  end

  describe "what a redirect would give up" do
    setup do
      %{
        options:
          Plugged.init(
            at: "/attachments",
            storage: %Presigned{},
            secret: {__MODULE__, :secret, []},
            metadata: {__MODULE__, :metadata, []}
          )
      }
    end

    test "anything but a safe image goes through the application instead", %{options: options} do
      # The promise that an SVG arrives as a download is made by headers a
      # redirect does not carry, and a script running on the bucket's origin
      # is often a script running on a subdomain of the application's.
      conn = get(signed("svg"), options)

      assert conn.status != 302
      assert get_resp_header(conn, "location") == []
    end

    test "a file with no recorded type is not redirected to either", %{options: options} do
      conn = get(signed(Coelho.Attachment.generate_key()), options)

      assert conn.status != 302
    end

    test "the storage is told what the file is, so it can presign it", %{options: options} do
      assert [location] = get_resp_header(get(signed("image"), options), "location")

      assert location =~ "type=image/png"
    end

    test "a signature with seconds left is served rather than presigned", %{options: options} do
      # Verification accepts `now <= expires`, so a request can arrive in the
      # signature's last second; presigning for that long gives a URL the
      # bucket refuses, and a request that used to work would start failing.
      now = System.system_time(:second)

      conn = get(signed("image", expires_in: 2, now: now), options)

      assert conn.status != 302
      assert get_resp_header(conn, "location") == []
    end
  end
end
