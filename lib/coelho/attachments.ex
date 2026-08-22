defmodule Coelho.Attachments do
  @moduledoc """
  Attachments referenced by key, resolved to a URL at render time.

  A stored attachment node carries an opaque key and the metadata worth
  showing — filename, content type, size — but never a URL:

      %{
        "type" => "attachment",
        "attrs" => %{"key" => "01J8Z…", "filename" => "plan.pdf", "content_type" => "application/pdf"}
      }

  The URL is produced when the document is rendered, from the `:context`
  passed to `Coelho.Render`:

      Coelho.to_html(document, schema, context: %{resolve: &MyApp.Uploads.url/1})

  What is stored is the key, never the URL, so every render asks again: a five
  minute signed URL is fine, moving a bucket is a resolver change rather than
  a data migration, and an attachment whose key no longer resolves degrades to
  its filename instead of a broken image.

  Resolving a stored reference late is not itself novel. What differs here is
  that the reference is an ordinary attribute of a validated node, so the walk
  that validates a document also enumerates what it points at — see `keys/2`.

  ## What Coelho does not do

  It does not store bytes and is not a storage layer: where the file lives —
  disk, object storage, anything else — and how a key becomes a URL are the
  application's. `Coelho.Attachment` only records the metadata that the editor
  and the renderer need.
  """

  alias Coelho.{Render, Schema, Storage}
  alias Coelho.Schema.{Attr, NodeSpec}

  @typedoc """
  What the renderer is given to turn a key into a URL: a function, a map of
  key to URL for attachments already loaded, or a map carrying either under
  `:resolve`.
  """
  @type context :: (String.t() -> String.t() | nil) | %{optional(any()) => any()}

  @doc """
  A signed, expiring URL for an attachment.

  This is what the render-time resolution is *for*: the signature covers the
  key and an expiry, so a URL that leaks stops working, and none of it is
  ever written into the document.

      Coelho.to_html(document, schema,
        context: %{resolve: &Coelho.Attachments.signed_url("/attachments", &1, secret)}
      )

  The secret must be at least 32 bytes and must not be the application's
  only secret if that one is also used elsewhere; derive it.
  """
  @spec signed_url(String.t(), String.t(), binary(), keyword()) :: String.t()
  def signed_url(base, key, secret, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 300)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    expires = now + expires_in

    "#{base}/#{key}?expires=#{expires}&signature=#{sign(key, expires, secret)}"
  end

  @doc """
  Checks a signature produced by `signed_url/4`.

  Takes the query parameters as a plug hands them over. Comparison is
  constant time, and an expired signature is refused even though it is
  valid.
  """
  @spec verify(String.t(), %{optional(String.t()) => String.t()}, binary(), keyword()) ::
          :ok | {:error, :invalid | :expired}
  def verify(key, params, secret, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, expires} <- integer_param(params, "expires"),
         signature when is_binary(signature) <- Map.get(params, "signature"),
         true <- constant_time_equal?(signature, sign(key, expires, secret)) do
      if now <= expires, do: :ok, else: {:error, :expired}
    else
      _ -> {:error, :invalid}
    end
  end

  defp sign(key, expires, secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{key}:#{expires}")
    |> Base.url_encode64(padding: false)
  end

  # A query parameter is whatever the client sent: `?expires[]=1` decodes to
  # a list, and `Integer.parse/1` would raise rather than refuse it.
  defp integer_param(params, name) do
    with value when is_binary(value) <- Map.get(params, name),
         {value, ""} <- Integer.parse(value) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  # Comparing signatures with `==` leaks their contents one byte at a time.
  defp constant_time_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp constant_time_equal?(_left, _right), do: false

  @doc """
  Every attachment key a document references, in document order.

  A node counts as an attachment when its schema spec declares a `:key`
  attribute, so a custom schema's own attachment-like nodes are found too.
  Useful for preloading, and for working out which stored blobs a document
  no longer refers to.
  """
  @spec keys(map(), Schema.t()) :: [String.t()]
  def keys(document, %Schema{} = schema \\ Schema.default()) do
    document |> collect_keys(schema) |> Enum.uniq()
  end

  @doc """
  The keys that are stored and that no document mentions any more.

  Deleting an image from a document leaves its bytes behind, so without
  something calling this a Coelho store only ever grows.

      stored = Repo.all(from a in Coelho.Attachment, select: a.key)
      documents = Repo.all(from p in Post, select: p.body)

      Coelho.Attachments.orphans(stored, documents)

  `stored_keys` is usually every `Coelho.Attachment` row: the table knows what
  was uploaded, where a storage may not be able to enumerate itself cheaply.

  `documents` is every document that could still be referring to something —
  every row of every rich text column. **Passing fewer deletes files that are
  still in use**, which is why this asks for the documents rather than going
  and finding them: only the application knows where they all are, and a
  half-answer here is data loss.

  Deleting is left to the caller for the same reason. `sweep/4` does it when
  the caller says so.
  """
  @spec orphans([String.t()], Enumerable.t(), Schema.t()) :: [String.t()]
  def orphans(stored_keys, documents, %Schema{} = schema \\ Schema.default()) do
    in_use =
      documents
      |> Stream.reject(&is_nil/1)
      |> Stream.flat_map(&keys(demand_document!(&1), schema))
      |> MapSet.new()

    Enum.reject(stored_keys, &MapSet.member?(in_use, &1))
  end

  # A document that is not a map refers to nothing as far as `keys/2` is
  # concerned, and answering that here would report every stored key as an
  # orphan and delete the lot. The shape most likely to arrive is a *string*:
  # an application storing its documents as JSON in a `:text` column — which
  # is exactly the migration `Coelho.HTML` exists for — selects the column and
  # gets binaries. `nil` is the one thing that legitimately means "no rich
  # text here"; anything else is a mistake worth stopping for.
  defp demand_document!(document) when is_map(document), do: document

  defp demand_document!(other) do
    raise ArgumentError, """
    expected a document, got: #{inspect(other, limit: 3)}

    Every element must be a decoded document — a map — or nil. A list of
    anything else looks like a list of documents referring to no attachments,
    and every stored key would be reported as an orphan.
    """
  end

  @doc """
  Deletes the stored keys no document mentions, returning what it removed.

  Pass `dry_run: true` to be told what would go without anything going —
  which is how this should be run the first time, against a real store.

      Coelho.Attachments.sweep(storage, keys, documents, dry_run: true)

  A refusal stops the sweep and hands back both the key that refused and
  everything already deleted, so the caller can still tidy the rows that now
  point at nothing:

      {:error, {key, reason}, removed} = Coelho.Attachments.sweep(storage, keys, documents)
  """
  @spec sweep(Storage.t(), [String.t()], Enumerable.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, {String.t(), term()}, [String.t()]}
  def sweep(storage, stored_keys, documents, opts \\ []) do
    schema = Keyword.get(opts, :schema, Schema.default())
    dry_run? = Keyword.get(opts, :dry_run, false)
    gone = orphans(stored_keys, documents, schema)

    if dry_run? do
      {:ok, gone}
    else
      Enum.reduce_while(gone, {:ok, []}, fn key, {:ok, removed} ->
        case Storage.delete(storage, key) do
          :ok -> {:cont, {:ok, [key | removed]}}
          # What was already deleted goes back with the error: the caller has
          # rows pointing at those bytes, and without the list it cannot tidy
          # them, so a table would keep pointing at files that are gone.
          {:error, reason} -> {:halt, {:error, {key, reason}, Enum.reverse(removed)}}
        end
      end)
      |> case do
        {:ok, removed} -> {:ok, Enum.reverse(removed)}
        error -> error
      end
    end
  end

  defp collect_keys(node, schema) when is_map(node) do
    own =
      with {:ok, %NodeSpec{attrs: %{key: %Attr{}}}} <- Schema.spec_of(schema, node),
           key when is_binary(key) <- node |> Map.get("attrs", %{}) |> Map.get("key") do
        [key]
      else
        _ -> []
      end

    own ++ Enum.flat_map(Map.get(node, "content", []), &collect_keys(&1, schema))
  end

  defp collect_keys(_node, _schema), do: []

  @doc """
  Resolves a key to a URL through the render context.
  """
  @spec resolve(context(), String.t() | nil) :: String.t() | nil
  def resolve(_context, nil), do: nil
  def resolve(fun, key) when is_function(fun, 1), do: fun.(key)

  def resolve(context, key) when is_map(context) do
    case Map.get(context, :resolve) do
      fun when is_function(fun, 1) -> fun.(key)
      %{} = urls -> Map.get(urls, key)
      nil -> nil
    end
  end

  def resolve(_context, _key), do: nil

  @doc """
  The URL to render for an attachment node, or `nil`.

  The resolver's answer goes through `Coelho.Render.safe_url/1`: a resolver
  is application code, but it is often fed straight from stored metadata,
  and the renderer is the last place a `javascript:` URL can be stopped.
  """
  @spec url(context(), map()) :: String.t() | nil
  def url(context, node) do
    context
    |> resolve(node |> Map.get("attrs", %{}) |> Map.get("key"))
    |> Render.safe_url()
  end
end
