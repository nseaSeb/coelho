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

  @type t :: %__MODULE__{
          default: term(),
          required: boolean(),
          validate: validator()
        }

  defstruct default: nil, required: false, validate: nil

  @allowed_schemes ~w(http https mailto tel)

  @doc """
  Builds an attribute spec from a keyword list.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      default: Keyword.get(opts, :default),
      required: Keyword.get(opts, :required, false),
      validate: Keyword.get(opts, :validate)
    }
  end

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
