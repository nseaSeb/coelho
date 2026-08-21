defmodule Coelho.Schema.Attr do
  @moduledoc """
  Specification and validation of a single node or mark attribute.

  An attribute spec declares a default value, whether the attribute is
  required, and an optional validator. Validators are declarative terms
  rather than closures so that a schema stays inspectable and comparable.

  Supported validators:

    * `:string`, `:integer`, `:boolean` — type checks
    * `{:one_of, list}` — value must be a member of `list`
    * `:safe_url` — relative URL, or absolute URL with an allowed scheme
    * `{:nullable, validator}` — accepts `nil`, otherwise delegates
    * a `fun/1` returning `:ok` or `{:error, message}` — escape hatch

  ## Turning a value into markup

  `:render_as` says how the value reaches the DOM, and — being data rather
  than a render function — it is applied by the server renderer *and*
  exported to the browser, so the editor shows what the page will carry
  without an application writing a hook.

    * `{:style, property}` — `style="property:value"`
    * `{:class, %{value => class}}` — the class the value maps to

  Alignment is the shipped example:

      align: [
        default: nil,
        validate: {:nullable, {:one_of, ~w(left center right justify)}},
        render_as: {:style, "text-align"}
      ]

  Swap that last line for a class map and the same attribute renders as a
  class an application's stylesheet can own — an inline style cannot be
  overridden by a rule:

      render_as: {:class, %{"center" => "text-center", "right" => "text-right"}}

  Both forms are closed over the values they name, which is the point.
  `Coelho.Ecto.Type` does not re-validate a stored document, so every
  renderer is a security boundary: a row written under a looser schema is
  rendered by today's renderer. A class map is its own allow list — a value
  that is not a key contributes nothing. `{:style, property}` has no such
  list of its own, so it is accepted only on an attribute whose validator is
  a `{:one_of, list}` (nullable or not), and the value is checked against
  that list again at render time.

  An attribute with no `:render_as` is not rendered by itself; a node's
  `:render` decides what to do with it, as before. A `:render` that is a
  *function* builds the whole element, so it is the one form `:render_as`
  cannot reach — the same rule a spec's `:class` follows.
  """

  @type validator ::
          :string
          | :integer
          | :boolean
          | {:one_of, [term()]}
          | :safe_url
          | {:nullable, validator()}
          | (term() -> :ok | {:error, String.t()})
          | nil

  @type render_as ::
          {:style, String.t()}
          | {:class, %{optional(term()) => String.t()}}
          | nil

  @type t :: %__MODULE__{
          default: term(),
          required: boolean(),
          validate: validator(),
          render_as: render_as()
        }

  defstruct default: nil, required: false, validate: nil, render_as: nil

  @allowed_schemes ~w(http https mailto tel)

  @doc """
  Builds an attribute spec from a keyword list.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    validate = Keyword.get(opts, :validate)

    %__MODULE__{
      default: Keyword.get(opts, :default),
      required: Keyword.get(opts, :required, false),
      validate: validate,
      render_as: build_render_as!(Keyword.get(opts, :render_as), validate)
    }
  end

  @doc """
  The values a `{:style, property}` attribute may render, or `nil`.

  Read off the validator, which such an attribute is required to have, so
  the list exists in one place and the browser can be handed the same one.
  """
  @spec render_values(t()) :: [term()] | nil
  def render_values(%__MODULE__{render_as: {:style, _property}, validate: validate}),
    do: one_of(validate)

  def render_values(%__MODULE__{}), do: nil

  defp build_render_as!(nil, _validate), do: nil

  # A style attribute carries a value straight into markup that nothing
  # downstream bounds, and `Coelho.Ecto.Type` does not re-validate a stored
  # document — so the allow list is required here rather than hoped for, at
  # the moment the schema is declared instead of the moment it renders.
  #
  # And its members must be strings, because a style is a string. A list of
  # integers would render nothing on the server and something in the
  # browser, where JSON turns the same list into numbers a value matches.
  defp build_render_as!({:style, property}, validate) when is_binary(property) do
    case one_of(validate) do
      nil ->
        raise ArgumentError,
              "render_as {:style, #{inspect(property)}} needs a {:one_of, list} validator " <>
                "(nullable or not), because a stored document is not re-validated on the " <>
                "way out and the value goes into a style attribute; got #{inspect(validate)}"

      allowed ->
        case Enum.reject(allowed, &(is_binary(&1) or is_nil(&1))) do
          [] ->
            {:style, property}

          other ->
            raise ArgumentError,
                  "render_as {:style, #{inspect(property)}} needs a validator whose values " <>
                    "are strings, since that is what a style carries; got #{inspect(other)}"
        end
    end
  end

  # The keys are compared against values read out of a stored document,
  # which came from JSON and are therefore never atoms — so an atom key is
  # taken as the string it was written as. `%{center: …}` is the natural
  # thing to write, and left alone it would match nothing on the server
  # while the browser, which sees the exported JSON, matched it.
  defp build_render_as!({:class, classes}, _validate) when is_map(classes) do
    normalized =
      Map.new(classes, fn
        {value, class} when is_binary(class) ->
          {class_key(value), class}

        {value, class} ->
          raise ArgumentError,
                "render_as {:class, …} maps a value to a class string, " <>
                  "got #{inspect(class)} for #{inspect(value)}"
      end)

    {:class, normalized}
  end

  defp build_render_as!(other, _validate) do
    raise ArgumentError,
          "render_as must be {:style, property} or {:class, %{value => class}}, " <>
            "got #{inspect(other)}"
  end

  # `true`, `false` and `nil` are atoms Elixir shares with JSON, and stay
  # themselves; any other atom is a name written the short way.
  defp class_key(key) when is_atom(key) and key not in [true, false, nil],
    do: Atom.to_string(key)

  defp class_key(key), do: key

  @doc """
  The key a `{:class, map}` lookup uses for a value, as the browser sees it.

  Exported alongside the classes so both halves agree on what a value is
  called: JavaScript indexes an object by the string form of the key, and
  `null` reaches it as `"null"`.
  """
  @spec class_json_key(term()) :: String.t()
  def class_json_key(nil), do: "null"
  def class_json_key(value), do: to_string(value)

  defp one_of({:one_of, allowed}) when is_list(allowed), do: allowed
  defp one_of({:nullable, validator}), do: one_of(validator)
  defp one_of(_validator), do: nil

  @doc """
  Runs a validator against a value.
  """
  @spec validate(validator(), term()) :: :ok | {:error, String.t()}
  def validate(nil, _value), do: :ok

  def validate(:string, value) when is_binary(value), do: :ok
  def validate(:string, _value), do: {:error, "must be a string"}

  def validate(:integer, value) when is_integer(value), do: :ok
  def validate(:integer, _value), do: {:error, "must be an integer"}

  def validate(:boolean, value) when is_boolean(value), do: :ok
  def validate(:boolean, _value), do: {:error, "must be a boolean"}

  def validate({:one_of, allowed}, value) do
    if value in allowed do
      :ok
    else
      {:error, "must be one of #{inspect(allowed)}"}
    end
  end

  def validate({:nullable, _validator}, nil), do: :ok
  def validate({:nullable, validator}, value), do: validate(validator, value)

  def validate(:safe_url, value) when is_binary(value), do: safe_url(value)
  def validate(:safe_url, _value), do: {:error, "must be a string"}

  def validate(fun, value) when is_function(fun, 1) do
    case fun.(value) do
      :ok ->
        :ok

      {:error, message} when is_binary(message) ->
        {:error, message}

      other ->
        # `Coelho.Document.validate/2` answers with errors rather than
        # raising, so a misbehaving validator must fail as the schema bug it
        # is, naming itself, instead of surfacing as a CaseClauseError from
        # deep inside document validation.
        raise ArgumentError,
              "attribute validator #{inspect(fun)} returned #{inspect(other)}, " <>
                "expected :ok or {:error, message}"
    end
  end

  def validate(validator, _value) do
    raise ArgumentError, "unknown attribute validator #{inspect(validator)}"
  end

  # A URL is accepted when it carries no scheme (relative, anchor,
  # protocol-relative) or a scheme from the allow list. Control characters are
  # rejected outright: they are the usual way of smuggling "java\nscript:" past
  # a naive parser.
  defp safe_url(value) do
    if String.match?(value, ~r/[\x00-\x20\x7f]/) do
      {:error, "must not contain whitespace or control characters"}
    else
      case URI.parse(value) do
        %URI{scheme: nil} -> :ok
        %URI{scheme: scheme} when scheme in @allowed_schemes -> :ok
        %URI{scheme: scheme} -> {:error, "scheme #{inspect(scheme)} is not allowed"}
      end
    end
  end
end
