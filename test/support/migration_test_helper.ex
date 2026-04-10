defmodule Forja.MigrationTestHelper do
  alias Ecto.Adapters.SQL
  alias Forja.TestRepo, as: Repo

  def run_migration(module) do
    %Postgrex.Result{rows: [[max_version]]} =
      SQL.query!(Repo, "SELECT COALESCE(MAX(version), 0) FROM schema_migrations", [])

    version = max_version + 1
    Ecto.Migrator.up(Repo, version, module, log: false)
  end

  def table_exists? do
    %Postgrex.Result{rows: [[regclass]]} =
      SQL.query!(Repo, "SELECT to_regclass('public.forja_events')", [])

    not is_nil(regclass)
  end

  def drop_table_if_exists do
    SQL.query!(Repo, "DROP TABLE IF EXISTS forja_events CASCADE", [])
  end
end
