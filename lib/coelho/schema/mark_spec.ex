defmodule Coelho.Schema.MarkSpec do
  @moduledoc """
  Specification of a single mark type, such as `bold` or `link`.
  """

  alias Coelho.Schema.Attr

  @type t :: %__MODULE__{
          name: atom(),
          attrs: %{optional(atom()) => Attr.t()},
          render: Coelho.Schema.NodeSpec.render()
        }

  defstruct [:name, attrs: %{}, render: nil]
end
