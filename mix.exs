defmodule Forja.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/lucas-stellet/forja"

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
      description: "Event Bus with Oban-backed processing for Elixir."
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
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.17"},

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
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      extras: extras(),
      groups_for_modules: groups_for_modules(),
      groups_for_extras: groups_for_extras(),
      formatters: ["html"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/getting-started.md",
      "guides/architecture.md",
      "guides/telemetry.md",
      "guides/testing.md",
      "guides/for-agents.md",
      "guides/event-schemas.md",
      "guides/error-handling.md",
      "CHANGELOG.md": [title: "Changelog"]
    ]
  end

  defp groups_for_extras do
    [
      Introduction: ~r/README\.md/,
      Guides: ~r/guides\/.+\.md/
    ]
  end

  defp groups_for_modules do
    [
      Core: [
        Forja,
        Forja.Event,
        Forja.Config
      ],
      "Handlers & Behaviours": [
        Forja.Handler,
        Forja.DeadLetter,
        Forja.Event.Schema,
        Forja.ValidationError
      ],
      Infrastructure: [
        Forja.Processor,
        Forja.Registry,
        Forja.ObanListener,
        Forja.Telemetry
      ],
      Workers: [
        Forja.Workers.ProcessEventWorker,
        Forja.Workers.ReconciliationWorker
      ],
      Testing: [
        Forja.Testing
      ],
      "Mix Tasks": [
        Mix.Tasks.Forja.Install
      ]
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
