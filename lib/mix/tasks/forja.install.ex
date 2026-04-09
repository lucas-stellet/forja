defmodule Mix.Tasks.Forja.Install.Docs do
  @moduledoc false

  def short_doc do
    "Install and configure Forja for use in an application."
  end

  def example do
    "mix forja.install"
  end

  def long_doc do
    """
    Install and configure Forja for use in an application.

    This task will:

    - Generate the `forja_events` database migration
    - Add `Forja` to your application's supervision tree
    - Add `:forja_events` and `:forja_reconciliation` queues to your Oban config
    - Optionally configure the ReconciliationWorker crontab

    ## Example

    Install using the default Ecto repo:

    ```bash
    mix forja.install
    ```

    Specify a repo explicitly:

    ```bash
    mix forja.install --repo MyApp.Repo
    ```

    Skip reconciliation crontab setup:

    ```bash
    mix forja.install --no-reconciliation
    ```

    ## Options

    * `--repo` or `-r` - Specify the Ecto repo to use (auto-detected if not provided)
    * `--reconciliation` or `-R` - Include ReconciliationWorker crontab (default: true)
    * `--pubsub` or `-p` - Specify the PubSub module (auto-inferred if not provided)
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Forja.Install do
    @shortdoc Mix.Tasks.Forja.Install.Docs.short_doc()
    @moduledoc Mix.Tasks.Forja.Install.Docs.long_doc()

    use Igniter.Mix.Task

    alias __MODULE__.Docs
    alias Igniter.Libs.Ecto, as: IgniterEcto
    alias Igniter.Project.Application, as: IgniterApp
    alias Igniter.Project.Config, as: IgniterConfig
    alias Igniter.Project.Formatter, as: IgniterFormatter
    alias Igniter.Project.Module, as: IgniterModule

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :forja,
        adds_deps: [],
        installs: [],
        example: Docs.example(),
        only: nil,
        positional: [],
        composes: [],
        schema: [
          repo: :string,
          reconciliation: :boolean,
          pubsub: :string
        ],
        defaults: [reconciliation: true],
        aliases: [r: :repo, R: :reconciliation, p: :pubsub],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = IgniterApp.app_name(igniter)
      opts = igniter.args.options

      case extract_repo(igniter, opts[:repo]) do
        {:ok, igniter, repo} ->
          pubsub = resolve_pubsub(igniter, opts[:pubsub])

          forja_opts =
            quote do
              [
                name: unquote(app_name),
                repo: unquote(repo),
                pubsub: unquote(pubsub),
                handlers: []
              ]
            end

          migration_body = """
          def change do
            create table(:forja_events, primary_key: false) do
              add :id, :binary_id, primary_key: true
              add :type, :string, null: false
              add :payload, :map, default: "{}"
              add :meta, :map, default: "{}"
              add :source, :string
              add :processed_at, :utc_datetime_usec
              add :idempotency_key, :string
              add :reconciliation_attempts, :integer, default: 0, null: false
              add :schema_version, :integer, default: 1, null: false
              add :correlation_id, :binary_id
              add :causation_id, :binary_id

              timestamps(type: :utc_datetime_usec, updated_at: false)
            end

            create index(:forja_events, [:type])
            create index(:forja_events, [:source])
            create index(:forja_events, [:inserted_at])
            create index(:forja_events, [:type, :source])

            create index(:forja_events, [:processed_at],
                     where: "processed_at IS NULL",
                     name: :forja_events_unprocessed
                   )

            create unique_index(:forja_events, [:idempotency_key],
                     where: "idempotency_key IS NOT NULL",
                     name: :forja_events_idempotency_key_index
                   )

            create index(:forja_events, [:processed_at, :inserted_at, :reconciliation_attempts],
                     where: "processed_at IS NULL",
                     name: :forja_events_reconciliation
                   )

            create index(:forja_events, [:correlation_id],
                     where: "correlation_id IS NOT NULL",
                     name: :forja_events_correlation_id
                   )

            create index(:forja_events, [:causation_id],
                     where: "causation_id IS NOT NULL",
                     name: :forja_events_causation_id
                   )
          end
          """

          oban_child =
            quote do
              Application.fetch_env!(unquote(app_name), Oban)
            end

          oban_migration_body = """
          def up, do: Oban.Migration.up()
          def down, do: Oban.Migration.down()
          """

          now = NaiveDateTime.utc_now()
          oban_ts = Calendar.strftime(now, "%Y%m%d%H%M%S")
          forja_ts = Calendar.strftime(NaiveDateTime.add(now, 1, :second), "%Y%m%d%H%M%S")

          igniter =
            IgniterEcto.gen_migration(igniter, repo, "add_oban_jobs_table",
              body: oban_migration_body,
              on_exists: :skip,
              timestamp: oban_ts
            )

          igniter =
            IgniterEcto.gen_migration(igniter, repo, "create_forja_events",
              body: migration_body,
              on_exists: :skip,
              timestamp: forja_ts
            )

          igniter
          |> IgniterApp.add_new_child(
            {Oban, {:code, oban_child}},
            after: [repo, Phoenix.PubSub]
          )
          |> IgniterApp.add_new_child(
            {Forja, {:code, forja_opts}},
            after: [repo, Phoenix.PubSub, Oban]
          )
          |> configure_oban(app_name, repo)
          |> maybe_configure_reconciliation_crontab(app_name, opts[:reconciliation])
          |> IgniterFormatter.import_dep(:forja)
          |> Igniter.add_notice("""

          Forja has been installed successfully!

          Next steps:

            1. Run `mix ecto.migrate` to create the oban_jobs and forja_events tables
            2. Add your event handler modules to the `handlers` list in the
               Forja supervision tree entry in your application.ex
            3. Configure Oban testing mode in config/test.exs:
               config :#{app_name}, Oban, testing: :inline

          For more information, see: https://hexdocs.pm/forja
          """)

        {:error, igniter} ->
          igniter
      end
    end

    # --- Private Helpers ---

    defp extract_repo(igniter, nil) do
      app_name = IgniterApp.app_name(igniter)

      case IgniterEcto.list_repos(igniter) do
        {igniter, [repo | _]} ->
          {:ok, igniter, repo}

        {igniter, []} ->
          issue = """
          No Ecto repos found for #{inspect(app_name)}.

          Ensure Ecto is installed and configured, then try again.
          You can also specify a repo explicitly:

              mix forja.install --repo MyApp.Repo
          """

          {:error, Igniter.add_issue(igniter, issue)}
      end
    end

    defp extract_repo(igniter, repo_string) do
      repo = IgniterModule.parse(repo_string)

      case IgniterModule.module_exists(igniter, repo) do
        {true, igniter} ->
          {:ok, igniter, repo}

        {false, igniter} ->
          {:error,
           Igniter.add_issue(
             igniter,
             "The specified repo #{inspect(repo)} does not exist in this project."
           )}
      end
    end

    defp resolve_pubsub(igniter, nil) do
      prefix = IgniterModule.module_name_prefix(igniter)
      Module.concat(prefix, PubSub)
    end

    defp resolve_pubsub(_igniter, pubsub_string) do
      IgniterModule.parse(pubsub_string)
    end

    defp configure_oban(igniter, app_name, repo) do
      igniter
      |> IgniterConfig.configure(
        "config.exs",
        app_name,
        [Oban, :repo],
        {:code, Macro.to_string(repo) |> Code.string_to_quoted!()},
        updater: fn zipper -> {:ok, zipper} end
      )
      |> IgniterConfig.configure(
        "config.exs",
        app_name,
        [Oban, :queues, :forja_events],
        5,
        updater: fn zipper -> {:ok, zipper} end
      )
      |> IgniterConfig.configure(
        "config.exs",
        app_name,
        [Oban, :queues, :forja_reconciliation],
        1,
        updater: fn zipper -> {:ok, zipper} end
      )
      |> IgniterConfig.configure(
        "test.exs",
        app_name,
        [Oban, :testing],
        :inline,
        updater: fn zipper -> {:ok, zipper} end
      )
    end

    defp maybe_configure_reconciliation_crontab(igniter, _app_name, false) do
      igniter
    end

    defp maybe_configure_reconciliation_crontab(igniter, _app_name, _truthy) do
      Igniter.add_notice(igniter, """

      To enable automatic reconciliation, add the ReconciliationWorker to your
      Oban crontab. In your config/config.exs, inside the Oban config:

          config :my_app, Oban,
            plugins: [
              {Oban.Plugins.Cron,
               crontab: [
                 {"0 * * * *", Forja.Workers.ReconciliationWorker, args: %{forja_name: "my_app"}}
               ]}
            ]

      The cron schedule "0 * * * *" runs once per hour. Adjust to match your
      reconciliation interval_minutes setting.
      """)
    end
  end
else
  defmodule Mix.Tasks.Forja.Install do
    @shortdoc Mix.Tasks.Forja.Install.Docs.short_doc()
    @moduledoc Mix.Tasks.Forja.Install.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'forja.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
