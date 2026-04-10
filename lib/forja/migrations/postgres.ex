defmodule Forja.Migrations.Postgres do
  @moduledoc """
  Internal PostgreSQL migration dispatcher for Forja.

  This module is the backend implementation for `Forja.Migration`. It tracks
  applied versions on the `forja_events` table comment and dispatches to version
  modules such as `Forja.Migrations.Postgres.V01`.

  Consumers should call `Forja.Migration` instead of this module directly.
  """

  use Ecto.Migration

  @current_version 1
  @table "forja_events"

  @doc """
  Returns the latest migration version supported by this dispatcher.

  ## Example

      iex> Forja.Migrations.Postgres.current_version()
      1
  """
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Migrates forward from the currently applied version to the target version.

  The target defaults to `current_version/0`. If `version:` is greater than the
  current dispatcher version, it is capped to the current version.

  ## Example

  ```elixir
  defmodule MyApp.Repo.Migrations.UpgradeForja do
    use Ecto.Migration

    def up, do: Forja.Migrations.Postgres.up(version: 1)
    def down, do: :ok
  end
  ```
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    migrated = migrated_version(opts)
    target = opts |> Keyword.get(:version, @current_version) |> min(@current_version)

    if migrated < target do
      Enum.each((migrated + 1)..target, &change(&1, :up, opts))
      set_version(target)
    end

    :ok
  end

  @doc """
  Migrates backward from the currently applied version to the target version.

  The target defaults to `0`, which drops all Forja migration versions.

  ## Example

  ```elixir
  defmodule MyApp.Repo.Migrations.RollbackForja do
    use Ecto.Migration

    def up, do: Forja.Migrations.Postgres.down(version: 0)
    def down, do: :ok
  end
  ```
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    migrated = migrated_version(opts)
    target = opts |> Keyword.get(:version, 0) |> max(0)

    if migrated > target do
      Enum.each(migrated..max(target + 1, 1), &change(&1, :down, opts))

      if target > 0 do
        set_version(target)
      end
    end

    :ok
  end

  @doc """
  Returns the version currently applied in the database.

  Pass `repo: YourApp.Repo` when calling outside an Ecto migration context.

  ## Example

  ```elixir
  Forja.Migrations.Postgres.migrated_version(repo: MyApp.Repo)
  ```
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_catalog.pg_class c
    WHERE c.relname = '#{@table}'
    """

    migration_repo =
      case Keyword.fetch(opts, :repo) do
        {:ok, repo} -> repo
        :error -> repo()
      end

    %{rows: rows} = migration_repo.query!(query, [])
    parse_version(rows)
  end

  defp change(version, direction, opts) do
    padded = version |> Integer.to_string() |> String.pad_leading(2, "0")
    module = Module.concat([__MODULE__, "V#{padded}"])
    apply(module, direction, [opts])
  end

  defp set_version(version) do
    execute("COMMENT ON TABLE #{@table} IS '#{version}'")
  end

  defp parse_version([]), do: 0
  defp parse_version([[nil]]), do: 0
  defp parse_version([[comment]]) when is_binary(comment), do: String.to_integer(comment)
end
