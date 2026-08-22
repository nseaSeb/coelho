if Code.ensure_loaded?(Ecto.ParameterizedType) do
  defmodule Coelho.Ecto.Type do
    @moduledoc """
    Ecto type storing a Coelho document in a `:map` (`jsonb`) column.

    The type carries the schema, so validation happens where Ecto already
    reports failures — in the changeset:

        schema "posts" do
          field :body, Coelho.Ecto.Type, document_schema: MyApp.RichText.schema()
        end

    The option is `:document_schema` and not `:schema` because Ecto injects
    its own `:schema` key — the owning Ecto schema module — into every
    parameterized type's options.

    `Coelho.Ecto.rich_text/2` is the shorter way to write the same thing.

    ## What casting accepts

      * a document map, as `Jason.decode/1` or ProseMirror's `toJSON()`
        produce it — validated and normalised
      * a JSON string, which is what a form posts back from the editor's
        hidden input — decoded, then validated
      * `nil` and `""`, which cast to `nil`

    A document failing validation makes the changeset invalid rather than
    raising, and the individual schema violations are attached to the error
    so a form can show them:

        {:error, changeset} = MyApp.Posts.create(%{body: hostile})
        changeset.errors
        #=> [body: {"is invalid rich text",
        #=>   [validation: :coelho,
        #=>    human: "block 1: unknown node type \\"script\\"",
        #=>    errors: ["content[0]: unknown node type \\"script\\""]]}]

    ## Writing past the cast

    Validation lives in `cast/3`, which is what a changeset built from
    parameters calls. `Ecto.Changeset.change/2` deliberately does not cast —
    that is its purpose in Ecto, and it applies here like anywhere else — so
    a map put through it is written as it stands:

        Ecto.Changeset.change(post, %{body: %{"type" => "nonsense"}})

    is a valid changeset. Nothing checks the document, and the row then
    renders as an error rather than as a page: `Coelho.Render` raises on a
    node type the schema does not declare rather than emitting it, which is
    the loud end of the two possible failures. Use `cast/3`, or hand
    `change/2` something that has already been through
    `Coelho.Document.validate/2` — what `Coelho.HTML.from_html/3` returns has
    been.

    ## Loading

    Values already in the database are loaded without re-validating them.
    A schema that grew stricter after rows were written would otherwise make
    old rows unreadable, which is a migration to run deliberately, not a
    failure to discover at read time. Renderers are written accordingly:
    `Coelho.Render` never derives markup structure from stored values.

    That is a floor, not a guarantee about the row. A document written under
    a looser schema, or by a direct SQL write, is not something `cast/3` ever
    saw. Put it through `Coelho.Document.sanitize/2` before rendering it
    somewhere a reader will see:

        post.body
        |> Coelho.sanitize(MyApp.RichText.schema())
        |> Coelho.to_html(MyApp.RichText.schema())
    """

    use Ecto.ParameterizedType

    alias Coelho.{Document, Schema}
    alias Coelho.Document.Error

    @impl true
    def type(_params), do: :map

    @impl true
    def init(opts) do
      case Keyword.fetch(opts, :document_schema) do
        {:ok, %Schema{} = schema} ->
          %{schema: schema}

        {:ok, other} ->
          raise ArgumentError,
                "Coelho.Ecto.Type expects :document_schema to be a %Coelho.Schema{}, " <>
                  "got #{inspect(other)}"

        :error ->
          %{schema: Schema.default()}
      end
    end

    @impl true
    def cast(nil, _params), do: {:ok, nil}
    def cast("", _params), do: {:ok, nil}

    def cast(document, %{schema: schema}) when is_map(document) do
      validate(document, schema)
    end

    def cast(json, %{schema: schema}) when is_binary(json) do
      case JSON.decode(json) do
        {:ok, document} when is_map(document) -> validate(document, schema)
        {:ok, _other} -> {:error, message: "is not a rich text document"}
        {:error, _reason} -> {:error, message: "is not valid JSON"}
      end
    end

    def cast(_other, _params), do: {:error, message: "is not a rich text document"}

    defp validate(document, schema) do
      case Document.validate(document, schema) do
        {:ok, document} ->
          {:ok, document}

        {:error, [first | _rest] = errors} ->
          # Both spellings, because they answer different questions: `:errors`
          # is what a developer reads in a log, `:human` is the one a form can
          # put in front of the person who typed it. Neither is a translation
          # — see `Coelho.Document.Error.describe/1` for that.
          {:error,
           message: "is invalid rich text",
           validation: :coelho,
           human: Error.humanize(first),
           errors: Enum.map(errors, &Error.format/1)}
      end
    end

    @impl true
    def load(nil, _loader, _params), do: {:ok, nil}
    def load(document, _loader, _params) when is_map(document), do: {:ok, document}
    def load(_other, _loader, _params), do: :error

    @impl true
    def dump(nil, _dumper, _params), do: {:ok, nil}
    def dump(document, _dumper, _params) when is_map(document), do: {:ok, document}
    def dump(_other, _dumper, _params), do: :error

    @impl true
    def equal?(left, right, _params), do: left == right
  end
end
