defmodule Forja.MigrationTest do
  use ExUnit.Case, async: false

  import Forja.MigrationTestHelper

  alias Ecto.Adapters.SQL.Sandbox
  alias Forja.Migration
  alias Forja.TestRepo, as: Repo

  doctest Forja.Migration

  defmodule UpMigration do
    use Ecto.Migration

    def up, do: Migration.up()
    def down, do: :ok
  end

  defmodule UpVersionOneMigration do
    use Ecto.Migration

    def up, do: Migration.up(version: 1)
    def down, do: :ok
  end

  defmodule DownMigration do
    use Ecto.Migration

    def up, do: Migration.down()
    def down, do: :ok
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

  describe "up/1 and down/1 delegation" do
    test "up/0 delegates and creates table" do
      run_migration(UpMigration)

      assert table_exists?()
      assert Migration.migrated_version(repo: Repo) == 1
    end

    test "down/0 delegates and drops table" do
      run_migration(UpMigration)
      assert table_exists?()

      run_migration(DownMigration)

      refute table_exists?()
      assert Migration.migrated_version(repo: Repo) == 0
    end

    test "up(version: 1) passes version option through" do
      run_migration(UpVersionOneMigration)

      assert table_exists?()
      assert Migration.migrated_version(repo: Repo) == 1
    end
  end

  describe "version helpers" do
    test "current_version/0 returns latest available version" do
      assert Migration.current_version() == 1
    end

    test "migrated_version/1 returns 0 on fresh database" do
      refute table_exists?()
      assert Migration.migrated_version(repo: Repo) == 0
    end

    test "migrated_version/1 returns current version after up/0" do
      run_migration(UpMigration)
      assert Migration.migrated_version(repo: Repo) == 1
    end
  end

end
