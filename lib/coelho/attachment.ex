if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Coelho.Attachment do
    @moduledoc """
    Metadata of one uploaded file, addressed by key.

    Coelho records what the editor and the renderer need to show an
    attachment — key, filename, content type, size — and nothing about where
    the bytes are. Storage stays the application's: this row is what a
    resolver looks up to build a URL. See `Coelho.Attachments`.

    Create the table with `mix coelho.gen.migration`.

        {:ok, attachment} =
          %Coelho.Attachment{}
          |> Coelho.Attachment.changeset(%{
            key: Coelho.Attachment.generate_key(),
            filename: "plan.pdf",
            content_type: "application/pdf",
            byte_size: 91_233
          })
          |> Repo.insert()

        Coelho.Attachment.to_node(attachment)
        #=> %{"type" => "attachment", "attrs" => %{"key" => "...", ...}}

    Nothing here is tied to an owner. A document references attachments by
    key, and `Coelho.Attachments.keys/2` answers which keys a document still
    uses — which is what a cleanup job needs, and is why the row carries no
    polymorphic association. `generate_key/1` takes a prefix when an
    application needs to list its own objects by tenant; read what that is
    and is not before reaching for it.
    """

    use Ecto.Schema

    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "coelho_attachments" do
      field(:key, :string)
      field(:filename, :string)
      field(:content_type, :string)
      field(:byte_size, :integer)
      field(:checksum, :string)
      field(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    @doc """
    Casts and validates attachment metadata.
    """
    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(attachment, attrs) do
      attachment
      |> cast(attrs, ~w(key filename content_type byte_size checksum metadata)a)
      |> validate_required(~w(key filename)a)
      |> validate_number(:byte_size, greater_than_or_equal_to: 0)
      |> unique_constraint(:key)
    end

    @doc """
    A fresh key.

    Keys are opaque and URL safe, and deliberately not derived from the
    filename: the key is what ends up inside stored documents, so it must
    survive a rename and must not leak what it points at.

    ## Prefixing, and what a prefix is not

    A key is global and opaque, which answers "what does this document point
    at" and never "whose is it". An application that backs up or purges per
    organisation has no way to list one organisation's objects without
    walking every document it owns, and `Coelho.Attachments.keys/2` is that
    walk. A prefix gives object storage something to list on instead:

        Coelho.Attachment.generate_key(prefix: "org_" <> org.slug)
        #=> "org_acme-QVmR0T7oKQyJ0y7Zzz5Wig"

    **A prefix is an inventory aid and never an authorization boundary.** The
    key arrives from the URL, which is to say from whoever sends the request,
    so a plug that read the organisation out of it would be asking the
    attacker which organisation they are in. What decides that is the
    connection — see the `:authorize` option of `Coelho.Plug.Attachments`.

    The prefix has to be URL safe and free of separators, because the key is
    one path segment and `Coelho.Storage.Disk` refuses anything else.

    **`Coelho.Storage.Disk` is the wrong place for one.** It shards on the
    first two characters of the key, which for `org_acme-…`, `org_beta-…` and
    every other organisation is `or` — so every prefixed attachment in the
    application lands in a single directory, which is precisely what the
    sharding is there to prevent. A prefix earns its keep against object
    storage, where listing by prefix is the operation it exists for; against
    Disk, either leave it off, or start it with something that varies.
    """
    @spec generate_key(keyword()) :: String.t()
    def generate_key(opts \\ []) do
      random = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      case Keyword.get(opts, :prefix) do
        nil -> random
        prefix -> valid_prefix!(prefix) <> "-" <> random
      end
    end

    defp valid_prefix!(prefix) when is_binary(prefix) do
      if String.match?(prefix, ~r/\A[A-Za-z0-9_-]+\z/) do
        prefix
      else
        raise ArgumentError,
              "an attachment key prefix must be URL safe and hold no separator, got " <>
                inspect(prefix)
      end
    end

    defp valid_prefix!(prefix) do
      raise ArgumentError, "an attachment key prefix must be a string, got #{inspect(prefix)}"
    end

    @doc """
    The document node referencing this attachment.

    Insert the result into the editor once an upload has been consumed.
    """
    @spec to_node(t()) :: map()
    def to_node(%__MODULE__{} = attachment) do
      %{
        "type" => "attachment",
        "attrs" => %{
          "key" => attachment.key,
          "filename" => attachment.filename,
          "content_type" => attachment.content_type,
          "byte_size" => attachment.byte_size,
          "alt" => nil,
          "caption" => nil
        }
      }
    end
  end
end
