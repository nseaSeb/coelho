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

  Keys come from `Coelho.Attachment.generate_key/0`. They are opaque and URL
  safe, and a storage must treat them as untrusted: `Coelho.Storage.Disk`
  refuses a key that is not what it hands out, so a key cannot walk out of
  the directory it belongs to.
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

  `opts` carries `:expires_in`, the seconds left on the signature that got
  the reader this far; a URL outliving it would widen the window the
  signature was there to narrow.

  Optional: a storage that has no such URL — the local filesystem — simply
  does not implement it.
  """
  @callback redirect_url(t(), key(), keyword()) :: {:ok, String.t()} | :error

  @optional_callbacks redirect_url: 3

  @spec put(t(), key(), source()) :: :ok | {:error, term()}
  def put(%module{} = storage, key, source), do: module.put(storage, key, source)

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
    if function_exported?(module, :redirect_url, 3) do
      module.redirect_url(storage, key, opts)
    else
      :error
    end
  end
end
