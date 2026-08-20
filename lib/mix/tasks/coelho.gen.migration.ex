defmodule Mix.Tasks.Coelho.Gen.Migration do
  @shortdoc "Generates the migration creating the coelho_attachments table"

  @moduledoc """
  Generates the migration for `Coelho.Attachment`.

      mix coelho.gen.migration

  Rich text fields themselves need no generator: `rich_text :body` stores its
  document inline, so the column is an ordinary `add :body, :map` in whatever
  migration already creates the table. Only attachments need a table of their
  own.

  ## Options

    * `--path` — where to write, `priv/repo/migrations` by default

  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: [path: :string])
    path = Keyword.get(opts, :path, "priv/repo/migrations")
    file = Path.join(path, "#{timestamp()}_create_coelho_attachments.exs")

    Mix.Generator.create_directory(path)
    Mix.Generator.create_file(file, migration(app_module()))

    file
  end

  defp app_module do
    Mix.Project.config()
    |> Keyword.fetch!(:app)
    |> Atom.to_string()
    |> Macro.camelize()
  end

  defp timestamp do
    %{year: y, month: m, day: d, hour: h, minute: min, second: s} = DateTime.utc_now()

    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, h, min, s])
    |> IO.iodata_to_binary()
  end

  defp migration(app) do
    """
    defmodule #{app}.Repo.Migrations.CreateCoelhoAttachments do
      use Ecto.Migration

      def change do
        create table(:coelho_attachments, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :key, :string, null: false
          add :filename, :string, null: false
          add :content_type, :string
          add :byte_size, :bigint
          add :checksum, :string
          add :metadata, :map, null: false, default: "{}"

          timestamps(type: :utc_datetime_usec)
        end

        # Documents reference attachments by key, so this is the lookup every
        # render goes through.
        create unique_index(:coelho_attachments, [:key])
      end
    end
    """
  end
end
