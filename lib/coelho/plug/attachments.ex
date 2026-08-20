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

    ## Serving other people's files

    Uploads served from the application's own origin are a standing hazard:
    a file the browser decides to render as HTML runs as the application.
    So the response always carries `x-content-type-options: nosniff`, and
    only a short list of image types is served inline. Everything else —
    including SVG, which is a document that can carry script — is sent as a
    download, whatever it claims to be.
    """

    @behaviour Plug

    import Plug.Conn

    alias Coelho.{Attachments, Storage}

    # Types a browser renders without being able to run anything.
    @inline_types ~w(image/png image/jpeg image/gif image/webp image/avif)

    @impl true
    def init(opts) do
      %{
        at: opts |> Keyword.fetch!(:at) |> String.split("/", trim: true),
        storage: Keyword.fetch!(opts, :storage),
        secret: Keyword.fetch!(opts, :secret),
        metadata: Keyword.get(opts, :metadata),
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

      case Attachments.verify(key, conn.query_params, resolve(options.secret)) do
        :ok -> send_bytes(conn, key, options)
        {:error, :expired} -> halt_with(conn, 410, "expired")
        {:error, :invalid} -> halt_with(conn, 403, "forbidden")
      end
    end

    defp send_bytes(conn, key, options) do
      storage = resolve(options.storage)

      # A storage with no local path — object storage — answers `:error` and
      # the bytes are read instead. Only the storage can tell an unusable key
      # from a missing one, so its own error decides the status.
      case Storage.path(storage, key) do
        {:ok, path} ->
          if File.regular?(path) do
            conn |> headers(key, options) |> send_file(200, path) |> halt()
          else
            halt_with(conn, 404, "not found")
          end

        :error ->
          case Storage.read(storage, key) do
            {:ok, bytes} -> conn |> headers(key, options) |> send_resp(200, bytes) |> halt()
            {:error, :invalid_key} -> halt_with(conn, 403, "forbidden")
            {:error, _reason} -> halt_with(conn, 404, "not found")
          end
      end
    end

    # Only on the way to a body: an error response carrying a
    # content-disposition makes the browser download the error text as a file.
    defp headers(conn, key, options) do
      metadata = metadata(options.metadata, key)

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

      if content_type(metadata) in @inline_types do
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
