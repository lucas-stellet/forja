defmodule Forja.Migrations.Postgres.V01Test do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Adapters.SQL
  alias Forja.Migrations.Postgres.V01
  alias Forja.TestRepo, as: Repo

  defmodule CreateV01Migration do
    use Ecto.Migration

    def up, do: V01.up([])
    def down, do: :ok
  end

  defmodule DropV01Migration do
    use Ecto.Migration

    def up, do: V01.down([])
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
      run_migration(CreateV01Migration)
    end)

    :ok
  end

  describe "up/1" do
    test "creates forja_events table with expected columns, types, defaults, and nullability" do
      run_migration(CreateV01Migration)

      assert table_exists?()

      columns = columns_by_name()

      assert Map.keys(columns) |> Enum.sort() == [
               "causation_id",
               "correlation_id",
               "id",
               "idempotency_key",
               "inserted_at",
               "meta",
               "payload",
               "processed_at",
               "reconciliation_attempts",
               "schema_version",
               "source",
               "type"
             ]

      assert columns["id"].udt_name == "uuid"
      assert columns["type"].udt_name == "varchar"
      assert columns["payload"].udt_name == "jsonb"
      assert columns["meta"].udt_name == "jsonb"
      assert columns["source"].udt_name == "varchar"
      assert columns["processed_at"].udt_name == "timestamp"
      assert columns["idempotency_key"].udt_name == "varchar"
      assert columns["reconciliation_attempts"].udt_name == "int4"
      assert columns["schema_version"].udt_name == "int4"
      assert columns["correlation_id"].udt_name == "uuid"
      assert columns["causation_id"].udt_name == "uuid"
      assert columns["inserted_at"].udt_name == "timestamp"

      assert columns["id"].is_nullable == "NO"
      assert columns["type"].is_nullable == "NO"
      assert columns["reconciliation_attempts"].is_nullable == "NO"
      assert columns["schema_version"].is_nullable == "NO"
      assert columns["inserted_at"].is_nullable == "NO"

      assert String.contains?(columns["payload"].column_default || "", "'{}'::jsonb")
      assert String.contains?(columns["meta"].column_default || "", "'{}'::jsonb")
      assert String.contains?(columns["reconciliation_attempts"].column_default || "", "0")
      assert String.contains?(columns["schema_version"].column_default || "", "1")
    end

    test "creates all required indexes with expected names and predicates" do
      run_migration(CreateV01Migration)

      indexes = indexes_by_name()

      assert Map.keys(indexes) |> Enum.sort() == [
               "forja_events_causation_id",
               "forja_events_correlation_id",
               "forja_events_idempotency_key_index",
               "forja_events_inserted_at_index",
               "forja_events_reconciliation",
               "forja_events_source_index",
               "forja_events_type_index",
               "forja_events_type_source_index",
               "forja_events_unprocessed"
             ]

      assert String.contains?(indexes["forja_events_unprocessed"], "WHERE (processed_at IS NULL)")

      assert String.contains?(
               indexes["forja_events_idempotency_key_index"],
               "WHERE (idempotency_key IS NOT NULL)"
             )

      assert String.contains?(indexes["forja_events_idempotency_key_index"], "UNIQUE")

      assert String.contains?(
               indexes["forja_events_reconciliation"],
               "WHERE (processed_at IS NULL)"
             )

      assert String.contains?(
               indexes["forja_events_correlation_id"],
               "WHERE (correlation_id IS NOT NULL)"
             )

      assert String.contains?(
               indexes["forja_events_causation_id"],
               "WHERE (causation_id IS NOT NULL)"
             )
    end
  end

  describe "down/1" do
    test "drops forja_events table" do
      run_migration(CreateV01Migration)
      assert table_exists?()

      run_migration(DropV01Migration)

      refute table_exists?()
    end

    test "is idempotent when table does not exist" do
      refute table_exists?()

      run_migration(DropV01Migration)
      run_migration(DropV01Migration)

      refute table_exists?()
    end
  end

  describe "full cycle" do
    test "up then down leaves database clean" do
      run_migration(CreateV01Migration)
      assert table_exists?()

      run_migration(DropV01Migration)

      refute table_exists?()
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

  defp columns_by_name do
    query = """
    SELECT column_name, udt_name, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'forja_events'
    """

    %Postgrex.Result{rows: rows} = SQL.query!(Repo, query, [])

    Map.new(rows, fn [name, udt_name, is_nullable, column_default] ->
      {name, %{udt_name: udt_name, is_nullable: is_nullable, column_default: column_default}}
    end)
  end

  defp indexes_by_name do
    query = """
    SELECT indexname, indexdef
    FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'forja_events' AND indexname != 'forja_events_pkey'
    """

    %Postgrex.Result{rows: rows} = SQL.query!(Repo, query, [])
    Map.new(rows, fn [indexname, indexdef] -> {indexname, indexdef} end)
  end
end
