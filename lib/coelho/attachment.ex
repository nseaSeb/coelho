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
    polymorphic association.
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
    """
    @spec generate_key() :: String.t()
    def generate_key, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

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
