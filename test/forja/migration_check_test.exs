defmodule Forja.MigrationCheckTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Forja.Config
  alias Forja.Migration
  alias Forja.TestRepo, as: Repo

  defmodule UpMigration do
    use Ecto.Migration

    def up, do: Migration.up()
    def down, do: :ok
  end

  defmodule DownMigration do
    use Ecto.Migration

    def up, do: Migration.down()
    def down, do: :ok
  end

  defmodule PubSub do
    defmacro __using__(_), do: :ok
  end

  setup_all do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  setup do
    drop_table_if_exists()

    on_exit(fn ->
      drop_table_if_exists()
      run_migration(UpMigration)
    end)

    :ok
  end

  describe "startup migration verification" do
    test "init/1 succeeds when migrated version is up to date" do
      run_migration(UpMigration)

      config =
        Config.new(
          name: :migration_check_ok,
          repo: Repo,
          pubsub: PubSub,
          migration_check: true
        )

      assert {:ok, _} = Forja.init(config)
    end

    test "init/1 raises with actionable message when schema is outdated" do
      required = Migration.current_version()
      migrated = Migration.migrated_version(repo: Repo)

      error =
        assert_raise RuntimeError, fn ->
          config =
            Config.new(
              name: :migration_check_outdated,
              repo: Repo,
              pubsub: PubSub,
              migration_check: true
            )

          Forja.init(config)
        end

      assert error.message =~ "Forja requires migration version #{required}"
      assert error.message =~ "database is at version #{migrated}"
      assert error.message =~ "Create a new Ecto migration and run `mix ecto.migrate`"
      assert error.message =~ "defmodule MyApp.Repo.Migrations.UpgradeForjaV#{required} do"
      assert error.message =~ "def up, do: Forja.Migration.up(version: #{required})"
      assert error.message =~ "def down, do: Forja.Migration.down(version: #{migrated})"
    end

    test "init/1 skips verification when migration_check is false" do
      refute table_exists?()

      config =
        Config.new(
          name: :migration_check_disabled,
          repo: Repo,
          pubsub: PubSub,
          migration_check: false
        )

      assert {:ok, _} = Forja.init(config)
    end
  end

  defp run_migration(module) do
    %Postgrex.Result{rows: [[max_version]]} =
      SQL.query!(Repo, "SELECT COALESCE(MAX(version), 0) FROM schema_migrations", [])

    version = max_version + 1
    Ecto.Migrator.up(Repo, version, module, log: false)
  end

  defp table_exists? do
    %Postgrex.Result{rows: [[regclass]]} =
      SQL.query!(Repo, "SELECT to_regclass('public.forja_events')", [])

    not is_nil(regclass)
  end

  defp drop_table_if_exists do
    SQL.query!(Repo, "DROP TABLE IF EXISTS forja_events CASCADE", [])
  end
end
