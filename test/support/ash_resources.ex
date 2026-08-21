defmodule Coelho.Test.RichText do
  @moduledoc false

  alias Coelho.Schema

  def schema, do: Schema.restrict(Schema.default(), nodes: [:paragraph], marks: [:bold, :link])
end

defmodule Coelho.Test.RichTextType do
  @moduledoc false
  use Coelho.Ash.Type
end

defmodule Coelho.Test.Post do
  @moduledoc false
  use Ash.Resource, domain: Coelho.Test.Domain

  attributes do
    uuid_primary_key(:id)

    attribute :body, Coelho.Test.RichTextType do
      public?(true)
      constraints(document_schema: Coelho.Test.RichText.schema())
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:body])
    end
  end
end

defmodule Coelho.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Coelho.Test.Post)
  end
end
