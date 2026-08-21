if Code.ensure_loaded?(Plug) do
  defmodule Coelho.Plug.Attachments do
    @moduledoc """
    Serves attachment bytes, behind a signature.

        plug Coelho.Plug.Attachments,
          at: "/attachments",
          storage: Coelho.Storage.Disk.new("priv/uploads"),
          secret: {MyApp.Uploads, :secret, []},
          metadata: {MyApp.Uploads, :metadata, []}

    Requests that do not match `:at` fall through untouched.

    ## Options

      * `:at` — the path prefix to serve from, required
      * `:storage` — a `Coelho.Storage`, or an `{m, f, a}` returning one,
        required. The `{m, f, a}` form matters in an endpoint, where `init/1`
        may run at compile time and a storage built then would freeze the
        configuration it was built from
      * `:secret` — the signing secret, as a binary or an `{m, f, a}` read at
        request time, required. It has to match what built the URL; see
        `Coelho.Attachments.signed_url/4`
      * `:metadata` — an `{m, f, a}` called with the key, returning
        `%{content_type: …, filename: …}` or `nil`. Coelho does not hold a
        repo, so this is how the row reaches the response
      * `:authorize` — an `{m, f, a}` or a `fun/2`, called with the
        connection and the key once the signature has checked out. Return
        `:ok` or `true` to serve, anything else to refuse. See below

    ## A signature says the URL is genuine, not that it is yours

    A signed URL is a bearer token: whoever holds it, holds the file. That is
    the right answer for a single-tenant application and the wrong one the
    moment there is more than one tenant, because the signature is checked
    against the secret and the secret is the *application's*. A URL minted
    for one organisation, forwarded or logged or pasted, is served to anyone
    who replays it.

    Mounting this behind the application's authentication pipeline does not
    close it. That answers "may this person use the application", never "is
    this file theirs": a signed URL belonging to organisation A, replayed by
    a signed-in member of organisation B, passes the pipeline *and* the
    signature. Do mount it behind authentication — this needs a connection
    that already knows who is asking — but do not mistake it for the check.

    `:authorize` is the check:

        plug Coelho.Plug.Attachments,
          at: "/attachments",
          storage: {MyApp.Uploads, :storage, []},
          secret: {MyApp.Uploads, :secret, []},
          authorize: {MyApp.Uploads, :authorize, []}

        def authorize(conn, key) do
          case conn.assigns[:current_organisation] do
            nil -> :error
            organisation -> MyApp.Uploads.owned_by?(key, organisation)
          end
        end

    The organisation comes from the connection, and never from the key. The
    key arrives in the URL, which is to say from whoever sent the request, so
    deriving the tenant from it is asking the attacker which tenant they are
    in — see `Coelho.Attachment.generate_key/1` on why a key prefix is an
    inventory aid and not this.

    Without `:authorize`, the signature is the only thing between a request
    and the bytes. That is deliberate, and it is documented rather than
    defaulted, because a default here would either break every single-tenant
    application or quietly do nothing.

    ## Serving other people's files


    Uploads served from the application's own origin are a standing hazard:
    a file the browser decides to render as HTML runs as the application.
    So a response carrying bytes always has `x-content-type-options: nosniff`,
    and only a short list of image types is served inline. Everything else —
    including SVG, which is a document that can carry script — is sent as a
    download, whatever it claims to be.

    A redirect carries none of those headers, which is why one is only offered
    for the types that would have been served inline anyway, and why a storage
    implementing `c:Coelho.Storage.redirect_url/3` is expected to honour the
    `:content_type` it is given.
    """

    @behaviour Plug

    import Plug.Conn

    alias Coelho.{Attachments, Storage}

    # Types a browser renders without being able to run anything.
    @inline_types ~w(image/png image/jpeg image/gif image/webp image/avif)

    # A signature is good up to and including its expiry, so a request can
    # arrive with a second left on it. Presigning for that long produces a URL
    # the bucket refuses; below this the bytes go through the application,
    # which always works.
    @shortest_redirect 5

    @impl true
    def init(opts) do
      %{
        at: opts |> Keyword.fetch!(:at) |> String.split("/", trim: true),
        storage: Keyword.fetch!(opts, :storage),
        secret: Keyword.fetch!(opts, :secret),
        metadata: Keyword.get(opts, :metadata),
        authorize: Keyword.get(opts, :authorize),
        cache_control: Keyword.get(opts, :cache_control, "private, no-store")
      }
    end

    @impl true
    def call(%Plug.Conn{} = conn, options) do
      # A prefix match, not a set difference: the key has to sit directly
      # under the mount point and nowhere else.
      if List.starts_with?(conn.path_info, options.at) do
        case Enum.drop(conn.path_info, length(options.at)) do
          [key] -> serve(conn, key, options)
          _ -> conn
        end
      else
        conn
      end
    end

    defp serve(conn, key, options) do
      conn = fetch_query_params(conn)

      # The signature is checked first because it is cheap and refuses the
      # bulk of what a scanner sends, and because `:authorize` is free to
      # reach for a database that a request with a forged signature has no
      # business touching.
      case Attachments.verify(key, conn.query_params, resolve(options.secret)) do
        :ok -> authorize(conn, key, options)
        {:error, :expired} -> halt_with(conn, 410, "expired")
        {:error, :invalid} -> halt_with(conn, 403, "forbidden")
      end
    end

    defp authorize(conn, key, %{authorize: nil} = options), do: serve_bytes(conn, key, options)

    defp authorize(conn, key, options) do
      # The same answer as a bad signature, deliberately: telling a caller
      # apart "this file does not exist" from "this file is not yours" is
      # telling them the file exists.
      if allowed?(options.authorize, conn, key) do
        serve_bytes(conn, key, options)
      else
        halt_with(conn, 403, "forbidden")
      end
    end

    defp allowed?({module, function, args}, conn, key),
      do: allowed?(apply(module, function, [conn, key | args]))

    defp allowed?(fun, conn, key) when is_function(fun, 2), do: allowed?(fun.(conn, key))

    defp allowed?(:ok), do: true
    defp allowed?(true), do: true
    defp allowed?(_other), do: false

    defp serve_bytes(conn, key, options) do
      storage = resolve(options.storage)

      metadata = metadata(options.metadata, key)
      remaining = seconds_left(conn)

      # Object storage can hand out a URL of its own, and redirecting to it is
      # what stops every byte travelling through the application. The
      # signature is checked first either way, so this trades the transfer and
      # not the check.
      #
      # It is only offered for the types that would have been served inline
      # anyway. Everything else — SVG, anything the bucket recorded as HTML —
      # goes through the application, because the promise that it arrives as a
      # download is made by headers this response would not carry, and a
      # script running on the bucket's origin is often a script running on a
      # subdomain of the application's.
      if inline?(metadata) and remaining >= @shortest_redirect do
        redirect(conn, storage, key, metadata, remaining, options)
      else
        send_bytes(conn, storage, key, metadata, options)
      end
    end

    defp redirect(conn, storage, key, metadata, remaining, options) do
      # The URL is given only what is left of the signature that got the
      # reader this far: one outliving it would widen the window the signature
      # was there to narrow. The metadata goes too, so an adapter that can
      # presign a content type or a filename does.
      opts = [
        expires_in: remaining,
        content_type: content_type(metadata),
        filename: Map.get(metadata || %{}, :filename)
      ]

      case Storage.redirect_url(storage, key, opts) do
        {:ok, url} ->
          # Not the cache lifetime chosen for the bytes: this response carries
          # a URL that stops working when the signature does, and a redirect
          # cached past that point turns every later load into the bucket's
          # 403 with nothing the application can do about it.
          conn
          |> put_resp_header("cache-control", "private, max-age=#{remaining}")
          |> put_resp_header("location", url)
          |> send_resp(302, "")
          |> halt()

        :error ->
          send_bytes(conn, storage, key, metadata, options)
      end
    end

    defp seconds_left(conn) do
      case conn.query_params |> Map.get("expires", "") |> Integer.parse() do
        {expires, ""} -> max(expires - System.system_time(:second), 0)
        _ -> 0
      end
    end

    defp inline?(metadata), do: content_type(metadata) in @inline_types

    defp send_bytes(conn, storage, key, metadata, options) do
      # A storage with no local path — object storage — answers `:error` and
      # the bytes are read instead. Only the storage can tell an unusable key
      # from a missing one, so its own error decides the status.
      case Storage.path(storage, key) do
        {:ok, path} ->
          if File.regular?(path) do
            conn |> headers(metadata, options) |> send_file(200, path) |> halt()
          else
            halt_with(conn, 404, "not found")
          end

        :error ->
          case Storage.read(storage, key) do
            {:ok, bytes} ->
              conn |> headers(metadata, options) |> send_resp(200, bytes) |> halt()

            {:error, :invalid_key} ->
              halt_with(conn, 403, "forbidden")

            {:error, _reason} ->
              halt_with(conn, 404, "not found")
          end
      end
    end

    # Only on the way to a body: an error response carrying a
    # content-disposition makes the browser download the error text as a file.
    # The metadata is looked up once per request and carried: an application's
    # `metadata/1` is often a query, and may well be where it records a
    # download.
    defp headers(conn, metadata, options) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", options.cache_control)
      |> put_resp_header("content-type", content_type(metadata))
      |> put_resp_header("content-disposition", disposition(metadata))
    end

    # The content type comes from whatever was recorded at upload time, which
    # is ultimately the browser's word. Anything that is not a plain type
    # token is not passed on: a header value with a control character in it
    # raises inside Plug and turns every fetch of that file into a 500.
    defp content_type(%{content_type: type}) when is_binary(type) do
      if String.match?(type, ~r{\A[\w.+-]+/[\w.+-]+\z}),
        do: type,
        else: "application/octet-stream"
    end

    defp content_type(_metadata), do: "application/octet-stream"

    defp disposition(metadata) do
      filename = Map.get(metadata || %{}, :filename)

      if inline?(metadata) do
        "inline"
      else
        # The filename is quoted and stripped of quotes and control
        # characters; it comes from whatever the uploader called the file.
        ~s(attachment; filename="#{sanitise(filename)}")
      end
    end

    defp sanitise(nil), do: "download"

    defp sanitise(filename) do
      filename
      |> Path.basename()
      |> String.replace(~r/[^\w.\- ]/u, "")
      |> case do
        "" -> "download"
        name -> name
      end
    end

    defp resolve({module, function, args}), do: apply(module, function, args)
    defp resolve(value), do: value

    defp metadata(nil, _key), do: nil
    defp metadata({module, function, args}, key), do: apply(module, function, args ++ [key])

    defp halt_with(conn, status, body) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(status, body)
      |> halt()
    end
  end
end
