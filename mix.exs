defmodule Forja.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/forgeworksio/forja"

  def project do
    [
      app: :forja,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      name: "Forja",
      docs: docs(),
      description: "Event Bus with dual-path processing for Elixir -- PubSub latency with Oban guarantees."
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.18"},
      {:gen_stage, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:jason, "~> 1.4"},

      # Code generation / installer
      {:igniter, "~> 0.7", optional: true},

      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Forgeworks"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Forja",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["format", "credo --strict", "dialyzer"]
    ]
  end
end
