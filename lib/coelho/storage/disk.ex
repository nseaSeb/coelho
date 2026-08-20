defmodule Coelho.Storage.Disk do
  @moduledoc """
  Attachment bytes on the local filesystem.

  Enough to run an application on one machine, and to have something
  concrete to point `Coelho.Attachments` at while the storage question is
  still open:

      storage = Coelho.Storage.Disk.new("priv/uploads")

  Files are sharded on the first two characters of the key, because a single
  directory holding every attachment stops being a good idea sooner than
  people expect.
  """

  @behaviour Coelho.Storage

  @type t :: %__MODULE__{root: Path.t()}

  defstruct [:root]

  @doc """
  A storage rooted at `root`, which is created on first write.
  """
  @spec new(Path.t()) :: t()
  def new(root) when is_binary(root), do: %__MODULE__{root: root}

  @impl true
  def put(storage, key, source) do
    with {:ok, path} <- path(storage, key),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      case source do
        {:binary, binary} -> File.write(path, binary)
        {:file, from} -> with {:ok, _bytes} <- File.copy(from, path), do: :ok
      end
    else
      :error -> {:error, :invalid_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def read(storage, key) do
    case path(storage, key) do
      {:ok, path} -> File.read(path)
      :error -> {:error, :invalid_key}
    end
  end

  @impl true
  def delete(storage, key) do
    case path(storage, key) do
      {:ok, path} -> remove(path)
      :error -> {:error, :invalid_key}
    end
  end

  # Removing what is not there is not an error: a cleanup job should be able
  # to run twice.
  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(storage, key) do
    case path(storage, key) do
      {:ok, path} -> File.regular?(path)
      :error -> false
    end
  end

  @impl true
  def path(%__MODULE__{root: root}, key) do
    # A key reaches this from a URL, so it is untrusted until it is checked
    # against the shape `Coelho.Attachment.generate_key/0` produces. Anything
    # else — a slash, a dot, an empty string — never becomes a path segment.
    if valid_key?(key) do
      {:ok, Path.join([root, String.slice(key, 0, 2), key])}
    else
      :error
    end
  end

  defp valid_key?(key) when is_binary(key) and byte_size(key) >= 3,
    do: String.match?(key, ~r/\A[A-Za-z0-9_-]+\z/)

  defp valid_key?(_key), do: false
end
