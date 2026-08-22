defmodule Coelho.Ash.Type do
  @moduledoc """
  A Coelho document as an Ash attribute, stored in a `:map` column.

  `Coelho.Ecto.Type` targets an Ecto schema, and Ash does not go through
  `Ecto.Type` for its own attributes, so an Ash resource declaring
  `attribute :body, :map` gets a map and no validation at all.

  ## Why this is a `use` rather than a ready-made type

  Coelho does not depend on Ash — not even optionally. An optional
  dependency would be the usual way to ship a module that needs another
  library at compile time, but Ash depends on `:stream_data` in every
  environment, and Coelho keeps `:stream_data` to `:dev` and `:test` for its
  property tests. Reconciling the two means loosening Coelho's own
  dependencies for every application that will never use Ash.

  So the type is a macro that expands in *your* application, where Ash is
  present by definition. It costs one module:

      defmodule MyApp.RichText.Type do
        use Coelho.Ash.Type
      end

  and then reads the way any other Ash type does:

      attribute :cgv_doc, MyApp.RichText.Type do
        constraints document_schema: MyApp.RichText.cgv_schema()
      end

  The schema arrives as a **constraint** rather than as an option on the
  attribute, because that is where Ash puts per-attribute configuration and
  where `Ash.Resource.Info` will show it.

  ## Keeping the column you already have

  `storage_type/1`, `cast_stored/2`, `cast_input/2`, `dump_to_native/2`,
  `cast_atomic/2` and `constraints/0` are all overridable, which is what lets
  a field that is already a `:string` column become a document without a
  migration: encode on the way down, decode on the way up, and put the
  fallback for rows that still hold plain text inside the type — the one
  place every reader goes through by construction rather than by discipline.

      defmodule MyApp.RichText.Type do
        use Coelho.Ash.Type

        @impl true
        def storage_type(_constraints), do: :string

        @impl true
        def dump_to_native(value, constraints) do
          case super(value, constraints) do
            # A column that never holds NULL is a column `is_nil/1` never
            # finds and `allow_nil?` never catches: `JSON.encode!(nil)` is
            # the four characters "null", not the absence of a value.
            {:ok, nil} -> {:ok, nil}
            {:ok, document} -> {:ok, JSON.encode!(document)}
            other -> other
          end
        end

        @impl true
        def cast_stored(value, constraints) when is_binary(value) do
          # Decoding *succeeding* is not enough: "123", "true" and "null" are
          # valid JSON, so a legacy row holding one of them would be read as
          # a number rather than as the text somebody typed — and land as an
          # empty document with nothing said about it. A document is a map.
          case JSON.decode(value) do
            {:ok, document} when is_map(document) -> super(document, constraints)
            _not_a_document -> super(MyApp.RichText.from_plain_text(value), constraints)
          end
        end

        def cast_stored(value, constraints), do: super(value, constraints)
      end

  Validation still runs on the way in: what is overridden is where the bytes
  go, never whether the document is one.

  ## Constraints

    * `:document_schema` — required, the `Coelho.Schema` to validate against
    * `:sanitize?` — when true, a value that fails validation is put through
      `Coelho.Document.sanitize/2` and accepted instead of rejected.
      Defaults to `false`. Turn it on for an import path where refusing the
      whole document is worse than keeping a poorer one; leave it off
      wherever a person is typing, so they are told rather than silently
      corrected

  ## What casting accepts

    * a document map, as ProseMirror's `toJSON()` produces it
    * a JSON string, which is what a form posts back from the editor's
      hidden input
    * `nil` and `""`, which cast to `nil`

  ## What an invalid document looks like

  An `Ash.Error.Changes.InvalidAttribute` on the attribute, whose `vars`
  carry the location in the document tree — which is what lets a LiveView
  form say more than "is invalid":

      %Ash.Error.Changes.InvalidAttribute{
        field: :cgv_doc,
        message: "is not valid rich text (%{location}: %{reason})",
        vars: [location: "content[0].attrs.href", reason: "scheme \\"javascript\\" is not allowed", ...]
      }

  `vars[:errors]` holds every failure, formatted, not only the first.

  ## Atomic updates

  **A document cannot be updated atomically from an expression, and never
  will be.** Validating one means walking its tree in Elixir — resolving node
  types against the schema, matching content expressions, running attribute
  validators — and none of that can be handed to the database. `cast_atomic/2`
  therefore answers `{:not_atomic, reason}` with that sentence in it, so an
  action declaring `require_atomic? true` refuses with something a reader can
  act on rather than a shrug.

  A literal document is cast the ordinary way. Ash does that itself for a
  type like this one — it only calls `cast_atomic/2` for an expression, or
  once the type defines `handle_change/3` or `prepare_change/3` — and the
  generated callback answers the same thing Ash would, so the two paths
  cannot drift.

  What *does* go through atomically is an update given the document itself:

      # validated and applied, atomic or not
      Ash.Changeset.for_update(post, :update, %{body: document})

      # refused: nothing can validate this without reading it back
      Ash.Changeset.for_update(post, :update, %{})
      |> Ash.Changeset.atomic_update(:body, expr(fragment("? || ?", body, ^more)))

  So an action that touches this attribute wants `require_atomic? false`, and
  a bulk action over it will fall back to reading rows. That is the price of
  the document being validated at all; storing HTML and filtering tags would
  atomically store whatever it was given.

  ## Storage, and tenants

  There is nothing to configure. The attribute is a `:map`, so AshPostgres
  stores it as `jsonb` in the row that owns it — no side table, no join, and
  nothing about it interacts with `AshPostgres` multitenancy: a document
  belongs to the row, and the row belongs to wherever your tenancy puts it,
  schema-based or attribute-based alike.

  Attachments are the one place where that stops being automatic, because
  their bytes are not in the row. A key is opaque and global on purpose: it
  answers "what does this document point at" and never "whose is it". **What
  decides whose it is comes from the connection, never from the key** — the
  key arrives in a URL, which is to say from whoever sent the request. See
  the `:authorize` option of `Coelho.Plug.Attachments`, and
  `Coelho.Attachment.generate_key/1` on why a key prefix is an inventory aid
  and not a boundary.

  ## Loading

  Values already in the database are loaded without being re-validated, for
  the reason `Coelho.Ecto.Type` gives: a schema that grew stricter after
  rows were written would otherwise make old rows unreadable, which is a
  migration to run deliberately. Put a stored document through
  `Coelho.Document.sanitize/2` before rendering it.
  """

  alias Coelho.{Document, Schema}
  alias Coelho.Document.Error

  @doc false
  defmacro __using__(opts) do
    quote location: :keep do
      use Ash.Type, unquote(opts)

      @impl Ash.Type
      def storage_type(_constraints), do: :map

      @impl Ash.Type
      def constraints, do: Coelho.Ash.Type.constraints()

      @impl Ash.Type
      def cast_input(value, constraints),
        do: Coelho.Ash.Type.cast_input(value, constraints)

      @impl Ash.Type
      def cast_stored(value, constraints),
        do: Coelho.Ash.Type.cast_stored(value, constraints)

      @impl Ash.Type
      def dump_to_native(value, constraints),
        do: Coelho.Ash.Type.dump_to_native(value, constraints)

      @impl Ash.Type
      def cast_atomic(new_value, constraints) do
        # The expression check has to live here, where Ash exists.
        if Ash.Expr.expr?(new_value) do
          {:not_atomic, Coelho.Ash.Type.not_atomic_reason()}
        else
          # The type's own `cast_input/2` and not Coelho's, so that a module
          # overriding it — which `defoverridable` below invites — is honoured
          # on this path as well as on the ordinary one.
          #
          # And `{:ok, …}` rather than `{:atomic, …}`, which is what Ash's own
          # default answers here: the `{:atomic, …}` branch puts the value
          # straight into the changeset's atomics, past the `allow_nil?` and
          # required-attribute checks that `{:ok, …}` goes through. `nil` is a
          # value this type casts, so that difference is a document that can
          # be nulled on an attribute declaring it may not be.
          cast_input(new_value, constraints)
        end
      end

      defoverridable storage_type: 1,
                     constraints: 0,
                     cast_input: 2,
                     cast_stored: 2,
                     dump_to_native: 2,
                     cast_atomic: 2
    end
  end

  @doc """
  The constraint schema the generated type declares.
  """
  @spec constraints() :: keyword()
  def constraints do
    [
      document_schema: [
        type: {:struct, Schema},
        required: true,
        doc: "The `Coelho.Schema` documents in this attribute are validated against."
      ],
      sanitize?: [
        type: :boolean,
        default: false,
        doc: "Repair a document that fails validation instead of rejecting it."
      ]
    ]
  end

  @doc """
  Casts user supplied input — a document map, or the JSON a form posts back.
  """
  @spec cast_input(term(), keyword()) :: {:ok, map() | nil} | {:error, keyword()}
  def cast_input(value, _constraints) when value in [nil, ""], do: {:ok, nil}

  def cast_input(value, constraints) when is_binary(value) do
    case decode(value) do
      {:ok, decoded} -> cast_input(decoded, constraints)
      :error -> {:error, message: "is not valid JSON"}
    end
  end

  def cast_input(value, constraints) do
    schema = fetch_schema!(constraints)

    case Document.validate(value, schema) do
      {:ok, document} ->
        {:ok, document}

      {:error, errors} ->
        if Keyword.get(constraints, :sanitize?, false) do
          {:ok, Document.sanitize(value, schema)}
        else
          {:error, invalid(errors)}
        end
    end
  end

  @doc """
  Why a document cannot be updated atomically from an expression.
  """
  @spec not_atomic_reason() :: String.t()
  def not_atomic_reason do
    "a Coelho document is validated by walking its tree in Elixir — node types " <>
      "resolved against the schema, content expressions matched, attribute " <>
      "validators run — and none of that can be expressed to the database. An " <>
      "atomic update would either store an unvalidated document or validate " <>
      "nothing at all. Pass the document itself rather than an expression, or " <>
      "set require_atomic? false on the action."
  end

  @doc """
  Reads a value back out of the column, without re-validating it.
  """
  @spec cast_stored(term(), keyword()) :: {:ok, map() | nil}
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints) when is_map(value), do: {:ok, value}
  def cast_stored(_value, _constraints), do: {:ok, nil}

  @doc """
  Writes a value to the column.
  """
  @spec dump_to_native(term(), keyword()) :: {:ok, map() | nil} | :error
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints) when is_map(value), do: {:ok, value}
  def dump_to_native(_value, _constraints), do: :error

  defp fetch_schema!(constraints) do
    case Keyword.fetch(constraints, :document_schema) do
      {:ok, %Schema{} = schema} ->
        schema

      _other ->
        raise ArgumentError,
              "a Coelho.Ash.Type attribute needs a :document_schema constraint, " <>
                "for example `constraints document_schema: MyApp.RichText.schema()`"
    end
  end

  # Ash turns the whole keyword into the error's `vars`, and interpolates
  # `%{name}` in the message from them — so naming the first failure and
  # where it is costs nothing beyond putting them in the keyword, and the
  # rest of the failures ride along under `:errors` for a form that wants to
  # show more than one.
  #
  # The key is `:location` and not `:path` because Ash takes `:path` for
  # itself, to place the error in the resource: it never reaches `vars`, and
  # a message interpolating it would render `%{path}` verbatim.
  defp invalid([%Error{} = first | _rest] = errors) do
    [
      message: "is not valid rich text (%{location}: %{reason})",
      location: format_path(first.path),
      reason: first.message,
      human: Error.humanize(first),
      validation: :coelho,
      errors: Enum.map(errors, &Error.format/1)
    ]
  end

  defp format_path(path) do
    case Error.format_path(path) do
      "" -> "document"
      formatted -> formatted
    end
  end

  # `JSON` is in the standard library from Elixir 1.18, which is the version
  # this package requires, so a JSON dependency would buy nothing.
  defp decode(value) do
    case JSON.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> :error
    end
  end
end
