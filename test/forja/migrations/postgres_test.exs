defmodule Forja.Migrations.PostgresTest do
  use ExUnit.Case, async: false

  import Forja.MigrationTestHelper

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Forja.Migrations.Postgres
  alias Forja.TestRepo, as: Repo

  defmodule UpMigration do
    use Ecto.Migration

    def up, do: Postgres.up()
    def down, do: :ok
  end

  defmodule UpVersionOneMigration do
    use Ecto.Migration

    def up, do: Postgres.up(version: 1)
    def down, do: :ok
  end

  defmodule DownMigration do
    use Ecto.Migration

    def up, do: Postgres.down()
    def down, do: :ok
  end

  defmodule DownVersionOneMigration do
    use Ecto.Migration

    def up, do: Postgres.down(version: 1)
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

  describe "migrated_version/1" do
    test "returns 0 on fresh database when table does not exist" do
      refute table_exists?()
      assert Postgres.migrated_version(repo: Repo) == 0
    end

    test "returns 0 when table exists but has no comment" do
      SQL.query!(
        Repo,
        "CREATE TABLE forja_events (id uuid PRIMARY KEY)",
        []
      )

      assert table_exists?()
      assert table_comment() == nil
      assert Postgres.migrated_version(repo: Repo) == 0
    end

    test "returns migrated version after up/1 runs" do
      run_migration(UpMigration)
      assert Postgres.migrated_version(repo: Repo) == 1
    end

    test "works with explicit repo option outside migration context" do
      run_migration(UpMigration)
      assert Postgres.migrated_version(repo: Repo) == 1
    end
  end

  describe "up/1" do
    test "migrates to current version when called without args" do
      run_migration(UpMigration)
      assert Postgres.migrated_version(repo: Repo) == Postgres.current_version()
    end

    test "caps version to 1 when called with version: 1" do
      run_migration(UpVersionOneMigration)
      assert Postgres.migrated_version(repo: Repo) == 1
    end

    test "is a no-op when already at target version" do
      run_migration(UpMigration)
      assert Postgres.migrated_version(repo: Repo) == 1

      run_migration(UpMigration)
      assert Postgres.migrated_version(repo: Repo) == 1
    end

    test "updates table comment after successful migration" do
      run_migration(UpMigration)
      assert table_comment() == "1"
    end
  end

  describe "down/1" do
    test "drops everything when called without args" do
      run_migration(UpMigration)
      assert table_exists?()

      run_migration(DownMigration)

      refute table_exists?()
      assert Postgres.migrated_version(repo: Repo) == 0
    end

    test "reverts to version 1 with version: 1 when already at version 1" do
      run_migration(UpMigration)
      run_migration(DownVersionOneMigration)

      assert table_exists?()
      assert Postgres.migrated_version(repo: Repo) == 1
    end

    test "is a no-op when already at or below target version" do
      assert Postgres.migrated_version(repo: Repo) == 0
      run_migration(DownMigration)
      assert Postgres.migrated_version(repo: Repo) == 0
    end

    test "keeps tracked version at 0 after successful down to 0" do
      run_migration(UpMigration)
      run_migration(DownMigration)
      assert Postgres.migrated_version(repo: Repo) == 0
    end
  end

  describe "full cycle" do
    test "up then down returns to version 0" do
      run_migration(UpMigration)
      assert Postgres.migrated_version(repo: Repo) == 1

      run_migration(DownMigration)
      assert Postgres.migrated_version(repo: Repo) == 0
    end
  end

  defp table_comment do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_catalog.pg_class c
    WHERE c.relname = 'forja_events'
    """

    %Postgrex.Result{rows: rows} = SQL.query!(Repo, query, [])

    case rows do
      [[comment]] -> comment
      _ -> nil
    end
  end

end
