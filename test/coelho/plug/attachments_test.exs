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

  defmodule Pieces do
    @moduledoc "A storage that can read in pieces, the way object storage can."
    @behaviour Coelho.Storage

    defstruct files: %{}, fail_after: nil

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

    @impl true
    def stream(storage, key) do
      case Map.fetch(storage.files, key) do
        {:ok, bytes} -> {:ok, pieces(bytes, storage.fail_after)}
        :error -> :error
      end
    end

    defp pieces(bytes, nil), do: for(<<piece::binary-size(2) <- bytes>>, do: piece)

    # Lazily, and giving up partway, the way an object storage's own stream
    # gives up when the socket under it does.
    defp pieces(bytes, after_pieces) do
      bytes
      |> pieces(nil)
      |> Stream.with_index()
      |> Stream.map(fn {piece, index} ->
        if index >= after_pieces, do: raise("the storage gave up"), else: piece
      end)
    end
  end

  def latin1_metadata(_key),
    do: %{content_type: "application/pdf", filename: <<"caf", 0xE9, ".pdf">>}

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

  describe "a key that tries to leave the storage" do
    # The test adapter splits the path without decoding it, where Cowboy and
    # Bandit decode each segment — so `%2e%2e%2f` reaches a real application
    # as one segment holding `../`, and never reaches this suite that way.
    # The path is set directly here to exercise what production sees, with a
    # genuine signature so the key is what is being tested and not the
    # signature.
    defp traversing(key, options) do
      %{expires: expires, signature: signature} = signed_parts(key)

      :get
      |> conn("/attachments/x?expires=#{expires}&signature=#{signature}")
      |> Map.put(:path_info, ["attachments" | String.split(key, "/")])
      |> Plugged.call(options)
    end

    defp signed_parts(key) do
      url = signed(key)
      %{"expires" => expires, "signature" => signature} = URI.decode_query(URI.parse(url).query)

      %{expires: expires, signature: signature}
    end

    @tag :tmp_dir
    test "is refused however it is spelled", %{tmp_dir: tmp_dir, options: options} do
      outside = tmp_dir |> Path.join("..") |> Path.expand() |> Path.join("secret.txt")
      File.write!(outside, "secret")
      on_exit(fn -> File.rm(outside) end)

      # Two answers are safe, and which one comes back says where it was
      # stopped. A key holding a separator becomes several segments, and the
      # plug serves only what sits *directly* under its mount point, so it
      # declines the request entirely and the connection passes through
      # untouched — status `nil`. A key that stays one segment reaches the
      # storage, whose own validation refuses it.
      for key <- ["../secret.txt", "../../secret.txt", "/etc/passwd", "..", "a\0b", "..\\secret"] do
        conn = traversing(key, options)

        assert conn.status in [nil, 403, 404], "#{inspect(key)} answered #{conn.status}"
        refute (conn.resp_body || "") =~ "secret"
      end
    end

    @tag :tmp_dir
    test "one segment holding what a decoded %2e%2e%2f becomes is refused by the storage",
         %{tmp_dir: tmp_dir, options: options} do
      # The single-segment case is the one the mount-point check does not
      # answer, so it is the one the storage has to: `..%2fsecret.txt`
      # reaches a real application as one segment reading `../secret.txt`.
      outside = tmp_dir |> Path.join("..") |> Path.expand() |> Path.join("secret.txt")
      File.write!(outside, "secret")
      on_exit(fn -> File.rm(outside) end)

      %{expires: expires, signature: signature} = signed_parts("../secret.txt")

      conn =
        :get
        |> conn("/attachments/x?expires=#{expires}&signature=#{signature}")
        |> Map.put(:path_info, ["attachments", "../secret.txt"])
        |> Plugged.call(options)

      # 403 rather than 404: the storage answers `{:error, :invalid_key}` for
      # a key it will not touch, and only the storage can tell an unusable
      # key from a missing one.
      assert conn.status == 403
      refute conn.resp_body =~ "secret"
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

  describe "a storage that can read in pieces" do
    setup do
      storage = %Pieces{files: %{"image" => "remote bytes"}}

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

    test "is chunked rather than held whole on the heap", %{options: options} do
      conn = get(signed("image"), options)

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == "remote bytes"
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "a key it does not hold falls back to the read, and its answer", %{options: options} do
      assert %{status: 404} = get(signed("missing"), options)
    end

    test "a stream that fails halfway ends the body rather than the request" do
      # An object storage's enumerable is lazy, and what it fails with is an
      # exception rather than a return value. The status and the headers are
      # gone by then, so there is nothing left to say — and letting it through
      # reaches an error handler that tries to answer on a connection already
      # answered, burying the real reason under `AlreadySentError`.
      storage = %Pieces{files: %{"image" => "remote bytes"}, fail_after: 1}

      options =
        Plugged.init(
          at: "/attachments",
          storage: storage,
          secret: {__MODULE__, :secret, []},
          metadata: {__MODULE__, :metadata, []}
        )

      conn = get(signed("image"), options)

      # The pieces that made it are already on the wire — this connection is
      # the one from before the piece that failed, which is all the test
      # adapter keeps. What matters is that the request ends here, chunked
      # and halted, rather than raising over an answer already sent.
      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.halted
    end
  end

  describe "responses that carry no body of their own" do
    test "an error response does not tell the browser to save it", %{options: options} do
      conn = get(signed("html"), options)

      assert conn.status == 404
      assert get_resp_header(conn, "content-disposition") == []
    end
  end

  describe "a filename that is not valid UTF-8" do
    @tag :tmp_dir
    test "is stripped rather than raising", %{storage: storage, tmp_dir: _tmp_dir} do
      # A form submitted as latin-1 sends `café.pdf` as bytes that are not
      # valid UTF-8. A unicode-mode regex *raises* on those rather than
      # failing to match, which turns every fetch of that attachment into a
      # 500 — the same failure the content type was already defended against.
      key = store(storage, "latin")

      options =
        Plugged.init(
          at: "/attachments",
          storage: storage,
          secret: {__MODULE__, :secret, []},
          metadata: {__MODULE__, :latin1_metadata, []}
        )

      conn = get(signed(key), options)

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition == ~s(attachment; filename="caf.pdf")

      # Byte for byte, because "it looks right" is what let a stray 0xE9
      # through on Linux while it was stripped on macOS — the same call, the
      # same Elixir, a different build of the regex engine underneath.
      assert String.valid?(disposition)
      refute disposition =~ <<0xE9>>
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

  describe "authorize" do
    # A signed URL is a bearer token: whoever holds it, holds the file. In a
    # multi-tenant application that is the wrong answer, and neither the
    # signature nor the authentication pipeline around it can give the right
    # one — both answer questions about the request, never about whose file
    # this is.
    def owner(conn, key), do: if(conn.assigns[:owned] == key, do: :ok, else: :error)

    def refuse(_conn, _key), do: :error

    defp with_authorize(options, authorize) do
      Plugged.init(
        at: "/attachments",
        storage: options.storage,
        secret: {__MODULE__, :secret, []},
        metadata: {__MODULE__, :metadata, []},
        authorize: authorize
      )
    end

    defp get_as(url, options, owned) do
      :get |> conn(url) |> Plug.Conn.assign(:owned, owned) |> Plugged.call(options)
    end

    test "serves what the connection is allowed", %{storage: storage, options: options} do
      key = store(storage, "image", "png bytes")
      options = with_authorize(options, {__MODULE__, :owner, []})

      conn = get_as(signed(key), options, key)

      assert conn.status == 200
      assert conn.resp_body == "png bytes"
    end

    test "refuses a genuine signature for someone else's file", %{
      storage: storage,
      options: options
    } do
      key = store(storage, "image", "png bytes")
      options = with_authorize(options, {__MODULE__, :owner, []})

      conn = get_as(signed(key), options, "another-tenants-key")

      assert conn.status == 403
      assert conn.resp_body == "forbidden"
    end

    test "refuses in the same words a bad signature does", %{storage: storage, options: options} do
      key = store(storage, "image", "png bytes")

      refused = get(signed(key), with_authorize(options, {__MODULE__, :refuse, []}))
      unsigned = get("/attachments/" <> key, options)

      # Telling "this is not yours" apart from "this does not exist" tells the
      # caller it exists.
      assert refused.status == unsigned.status
      assert refused.resp_body == unsigned.resp_body
    end

    test "takes a function of the connection and the key", %{
      storage: storage,
      options: options
    } do
      key = store(storage, "image", "png bytes")
      options = with_authorize(options, fn _conn, _key -> true end)

      assert %{status: 200} = get(signed(key), options)
    end

    test "is not consulted when the signature already failed", %{
      storage: storage,
      options: options
    } do
      key = store(storage, "image", "png bytes")
      options = with_authorize(options, fn _conn, _key -> raise "should not be reached" end)

      assert %{status: 403} = get("/attachments/" <> key, options)
    end

    test "an expired signature is still expired, not forbidden", %{
      storage: storage,
      options: options
    } do
      key = store(storage, "image", "png bytes")
      options = with_authorize(options, fn _conn, _key -> true end)

      assert %{status: 410} = get(signed(key, expires_in: -1), options)
    end

    test "fails closed when it raises, rather than falling open", %{
      storage: storage,
      options: options
    } do
      # Nothing rescues, on purpose. A callback that cannot reach its database
      # has to stop the request, not guess at it — the alternative is a broken
      # check that serves everybody.
      key = store(storage, "image", "png bytes")
      options = with_authorize(options, fn _conn, _key -> raise "the database is gone" end)

      assert_raise RuntimeError, "the database is gone", fn -> get(signed(key), options) end
    end

    test "runs before the metadata is looked up, and before a URL is minted" do
      # A refusal costs one callback and no query — and object storage is
      # never asked to presign a file for a caller who is not allowed it.
      options =
        Plugged.init(
          at: "/attachments",
          storage: %Presigned{},
          secret: {__MODULE__, :secret, []},
          metadata: {__MODULE__, :explode, []},
          authorize: {__MODULE__, :refuse, []}
        )

      conn = get(signed("image"), options)

      assert conn.status == 403
      assert get_resp_header(conn, "location") == []
    end

    def explode(_key), do: raise("metadata should not be looked up for a refused request")

    test "without it the signature is the only check, which is deliberate", %{
      storage: storage,
      options: options
    } do
      key = store(storage, "image", "png bytes")

      assert %{status: 200} = get(signed(key), options)
    end
  end
end
