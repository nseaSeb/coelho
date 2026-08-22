defmodule Coelho.MixProject do
  use Mix.Project

  @version "0.11.0"
  @source_url "https://github.com/nseaSeb/coelho"

  def project do
    [
      app: :coelho,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Structured rich text for Phoenix: schema, validation, storage and rendering",
      package: package(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:error_handling, :extra_return, :missing_return, :unknown]
      ],
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  # The Ash resource the type is tested through has to be compiled before
  # protocols are consolidated, which a module defined inside a test file is
  # not.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def cli do
    [preferred_envs: [check: :test]]
  end

  # Everything CI runs that does not need a browser. The browser checks need
  # Linux to mean anything — see docker/README.md.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      {:ash, "~> 3.0", only: :test},
      {:ecto, "~> 3.11", optional: true},
      {:floki, "~> 0.36", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:plug, "~> 1.14", optional: true},
      {:telemetry, "~> 1.0", optional: true},
      {:stream_data, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      # `assets` as a whole would carry the node_modules symlink the schema
      # bridge check makes, which points nowhere on anybody else's machine.
      files:
        ~w(lib assets/js assets/css assets/package.json mix.exs README.md CHANGELOG.md LICENSE),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Document: [Coelho.Document, Coelho.Document.Error, Coelho.Render],
        Observing: [Coelho.Telemetry],
        Schema: [
          Coelho.Schema,
          Coelho.Schema.NodeSpec,
          Coelho.Schema.MarkSpec,
          Coelho.Schema.Attr,
          Coelho.Schema.ContentExpression,
          Coelho.Schema.Default
        ],
        Phoenix: [
          Coelho.Ecto,
          Coelho.Ecto.Type,
          Coelho.LiveView,
          Coelho.LiveViewTest,
          Coelho.Plug.Attachments
        ],
        Ash: [Coelho.Ash.Type],
        Attachments: [
          Coelho.Attachment,
          Coelho.Attachments,
          Coelho.Storage,
          Coelho.Storage.Disk
        ]
      ]
    ]
  end
end
