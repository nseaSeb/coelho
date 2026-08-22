defmodule Coelho.Storage do
  @moduledoc """
  Where the bytes of an attachment live.

  Coelho stores the document and the attachment metadata; the file itself is
  somebody else's problem, and this is the smallest contract that lets it be
  solved without writing the same glue in every application. A storage is a
  struct whose module implements these callbacks, so an application can point
  at the one it ships with — `Coelho.Storage.Disk` — or write its own for
  object storage without anything else changing.

      storage = Coelho.Storage.Disk.new("priv/uploads")

      :ok = Coelho.Storage.put(storage, key, {:file, upload_path})
      {:ok, path} = Coelho.Storage.path(storage, key)

  Keys come from `Coelho.Attachment.generate_key/1`. They are opaque and URL
  safe, and a storage must treat them as untrusted: `Coelho.Storage.Disk`
  refuses a key that is not what it hands out, so a key cannot walk out of
  the directory it belongs to.

  ## Writing one for object storage

  Coelho ships `Coelho.Storage.Disk` and nothing else, deliberately: an S3
  adapter means an HTTP client and a signing library, and a package whose
  document core has no dependencies at all should not acquire two so that
  applications not using object storage can carry them. Here is the whole
  thing, against [ExAws](https://hex.pm/packages/ex_aws_s3), to copy into an
  application and adjust:

      defmodule MyApp.Uploads.S3 do
        @behaviour Coelho.Storage

        defstruct [:bucket]

        def new(bucket), do: %__MODULE__{bucket: bucket}

        @impl true
        def put(%{bucket: bucket}, key, {:binary, binary}) do
          bucket |> ExAws.S3.put_object(key, binary) |> request()
        end

        def put(%{bucket: bucket}, key, {:file, path}) do
          path
          |> ExAws.S3.Upload.stream_file()
          |> ExAws.S3.upload(bucket, key)
          |> request()
        end

        @impl true
        def read(%{bucket: bucket}, key) do
          case bucket |> ExAws.S3.get_object(key) |> ExAws.request() do
            {:ok, %{body: body}} -> {:ok, body}
            {:error, {:http_error, 404, _response}} -> {:error, :enoent}
            {:error, reason} -> {:error, reason}
          end
        end

        # No local path: the plug falls back to read/2, or to the redirect
        # below, which is the one worth having.
        @impl true
        def path(_storage, _key), do: :error

        @impl true
        def delete(%{bucket: bucket}, key) do
          bucket |> ExAws.S3.delete_object(key) |> request()
        end

        @impl true
        def exists?(%{bucket: bucket}, key) do
          match?({:ok, _response}, bucket |> ExAws.S3.head_object(key) |> ExAws.request())
        end

        @impl true
        def redirect_url(%{bucket: bucket}, key, opts) do
          filename = Keyword.get(opts, :filename)

          ExAws.Config.new(:s3)
          |> ExAws.S3.presigned_url(:get, bucket, key,
            expires_in: Keyword.fetch!(opts, :expires_in),
            query_params:
              [{"response-content-type", Keyword.fetch!(opts, :content_type)}] ++
                if(filename,
                  do: [{"response-content-disposition", ~s(inline; filename="\#{filename}")}],
                  else: []
                )
          )
        end

        defp request(operation) do
          case ExAws.request(operation) do
            {:ok, _response} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
      end

  Two things to know before it goes to production.

  **`put/3` must stream a file, not read it.** The `{:file, path}` clause
  above uses `ExAws.S3.Upload`, which does a multipart upload; the obvious
  shortcut, `File.read!(path)` into `put_object`, holds the whole upload in
  memory per request.

  **ExAws over HTTP/2 fails above about a megabyte**, with
  `{:error, :send_buffer_full}` — the request outgrows the connection's send
  buffer and nothing retries it. A naive adapter meets it the first time
  someone attaches a real PDF, and it looks like a Coelho problem rather than
  a transport one. Pin the client to HTTP/1.1, or raise the buffer:

      config :ex_aws, :hackney_opts, protocols: [:http1]

  **`redirect_url/3` is the difference between a proxy and a redirect.**
  Without it, `Coelho.Plug.Attachments` falls back to `read/2` and every byte
  of every attachment travels through the application. With it, the plug
  checks its signature and then gets out of the way — and the presigned URL
  has to pin the `:content_type` it is given, because the headers the plug
  would have set do not survive a redirect. That is not decoration: it is
  what stops a file that lies about what it is from being rendered as
  whatever the bucket decides.
  """

  @type t :: struct()
  @type key :: String.t()
  @type source :: {:file, Path.t()} | {:binary, binary()}

  @doc "Stores the bytes under a key, replacing whatever was there."
  @callback put(t(), key(), source()) :: :ok | {:error, term()}

  @doc "Reads the bytes back."
  @callback read(t(), key()) :: {:ok, binary()} | {:error, term()}

  @doc """
  A local path for the bytes, when there is one.

  Lets a plug send the file rather than read it into memory. A remote
  storage answers `:error`, and the caller falls back to `read/2`.
  """
  @callback path(t(), key()) :: {:ok, Path.t()} | :error

  @doc "Removes the bytes. Removing what is not there is not an error."
  @callback delete(t(), key()) :: :ok | {:error, term()}

  @doc "Whether the storage holds anything under this key."
  @callback exists?(t(), key()) :: boolean()

  @doc """
  Somewhere the reader can fetch the bytes directly, when there is such a
  place.

  Object storage can hand out a URL of its own — presigned, short lived —
  and answering with one is what stops every byte travelling through the
  application. `Coelho.Plug.Attachments` redirects to it after checking its
  own signature, so the check still happens and the transfer does not.

  `opts` carries:

    * `:expires_in` — the seconds left on the signature that got the reader
      this far. A URL outliving it would widen the window the signature was
      there to narrow.
    * `:content_type` — what the application recorded for this file. **An
      implementation is expected to pin it**, through whatever its service
      offers — `response-content-type` on a presigned S3 URL, and the like.
      The plug's own defence against a file that lies about what it is lives
      in headers a redirect does not carry, so an implementation that passes
      this over hands that defence back to whatever the bucket decides.
    * `:filename` — for a service that can pin a download name too.

  Optional: a storage that has no such URL — the local filesystem — simply
  does not implement it.
  """
  @callback redirect_url(t(), key(), keyword()) :: {:ok, String.t()} | :error

  @optional_callbacks redirect_url: 3

  @spec put(t(), key(), source()) :: :ok | {:error, term()}
  def put(%module{} = storage, key, source) do
    Coelho.Telemetry.span(
      [:coelho, :storage],
      fn -> %{storage: module, key: key} end,
      fn -> module.put(storage, key, source) end,
      &%{result: elem_or(&1)}
    )
  end

  defp elem_or(:ok), do: :ok
  defp elem_or({:error, _reason}), do: :error
  defp elem_or(_other), do: :error

  # Reading is all or nothing: the whole object comes back as one binary, on
  # the heap of whichever process asked. `Coelho.Plug.Attachments` serves
  # from `path/2` where the storage has one — `send_file` streams and the
  # bytes never reach the VM — and falls back to this only for a storage that
  # has no local file, where N concurrent downloads hold N copies of the
  # object at once. A storage fronting large objects should implement
  # `redirect_url/3` and let the client fetch them from the bucket.
  @spec read(t(), key()) :: {:ok, binary()} | {:error, term()}
  def read(%module{} = storage, key), do: module.read(storage, key)

  @spec path(t(), key()) :: {:ok, Path.t()} | :error
  def path(%module{} = storage, key), do: module.path(storage, key)

  @spec delete(t(), key()) :: :ok | {:error, term()}
  def delete(%module{} = storage, key), do: module.delete(storage, key)

  @spec exists?(t(), key()) :: boolean()
  def exists?(%module{} = storage, key), do: module.exists?(storage, key)

  @doc """
  Asks the storage for a URL to redirect to, or `:error` when it has none.

  Answers `:error` for a storage that does not implement the callback, so
  callers need not know which do.
  """
  @spec redirect_url(t(), key(), keyword()) :: {:ok, String.t()} | :error
  def redirect_url(%module{} = storage, key, opts \\ []) do
    # `function_exported?/3` answers false for a module that has not been
    # loaded yet, which is ordinary under interactive code loading — and the
    # answer would be to stream every byte through the application, silently,
    # since the fallback works.
    if Code.ensure_loaded?(module) and function_exported?(module, :redirect_url, 3) do
      module.redirect_url(storage, key, opts)
    else
      :error
    end
  end
end
