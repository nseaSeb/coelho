if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Coelho.Ecto do
    @moduledoc """
    Declaring a rich text field on an Ecto schema.

    Coelho stores the document inline, in a `:map` (`jsonb`) column on the
    table that owns it, rather than in a side table the way Action Text
    does. Nothing here is polymorphic, so nothing needs a join: a post's body
    lives on the post, and `Ecto.Changeset.cast/3` validates it like any
    other field.

        defmodule MyApp.Post do
          use Ecto.Schema
          import Coelho.Ecto

          schema "posts" do
            field :title, :string
            rich_text :body
          end
        end

    The matching migration adds an ordinary map column:

        alter table(:posts) do
          add :body, :map
        end

    Pass `:document_schema` to use something other than
    `Coelho.Schema.default/0` — Ecto reserves `:schema` for the owning module.
    Build it once and hold it in a module, since it is read on every cast:

        defmodule MyApp.RichText do
          @schema Coelho.Schema.new(nodes: [...], marks: [...])
          def schema, do: @schema
        end

        rich_text :body, document_schema: MyApp.RichText.schema()

    """

    @doc """
    Declares a rich text field.

    Accepts the same options as `Ecto.Schema.field/3`, plus
    `:document_schema`.
    """
    defmacro rich_text(name, opts \\ []) do
      quote do
        Ecto.Schema.field(unquote(name), Coelho.Ecto.Type, unquote(opts))
      end
    end
  end
end
