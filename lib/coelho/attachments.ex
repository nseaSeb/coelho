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

  That indirection is the whole point. Storing rendered HTML bakes the URL
  into it, so signed and expiring URLs cannot work — the link is as old as the
  document. Here every render asks again, so a five minute signed URL is fine,
  moving a bucket is a resolver change rather than a data migration, and an
  attachment whose key no longer resolves degrades to its filename instead of
  a broken image.

  ## What Coelho does not do

  It does not store bytes and is not a storage layer: where the file lives —
  disk, object storage, anything else — and how a key becomes a URL are the
  application's. `Coelho.Attachment` only records the metadata that the editor
  and the renderer need.
  """

  alias Coelho.{Render, Schema}
  alias Coelho.Schema.{Attr, NodeSpec}

  @typedoc """
  What the renderer is given to turn a key into a URL: a function, a map of
  key to URL for attachments already loaded, or a map carrying either under
  `:resolve`.
  """
  @type context :: (String.t() -> String.t() | nil) | %{optional(any()) => any()}

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

  defp collect_keys(node, schema) when is_map(node) do
    own =
      with {:ok, type} <- Map.fetch(node, "type"),
           {:ok, name} <- Schema.resolve_node_name(schema, type),
           %NodeSpec{attrs: %{key: %Attr{}}} <- Schema.node_spec(schema, name),
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
