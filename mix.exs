defmodule Coelho.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
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
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ecto, "~> 3.11", optional: true},
      {:floki, "~> 0.36", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:plug, "~> 1.14", optional: true},
      {:stream_data, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib assets mix.exs README.md LICENSE),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
