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
end
