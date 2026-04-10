defmodule Forja.Migration do
  @moduledoc """
  Public API for Forja's versioned PostgreSQL migrations.

  Use this module inside your Ecto migration files. It delegates to
  `Forja.Migrations.Postgres` and applies only the required migration delta.

  ## Setup

  Create a migration that installs Forja at the latest known version:

  ```elixir
  defmodule MyApp.Repo.Migrations.SetupForja do
    use Ecto.Migration

    def up, do: Forja.Migration.up()
    def down, do: Forja.Migration.down()
  end
  ```

  ## Upgrade

  When a newer Forja release requires a new migration version, target that
  version explicitly:

  ```elixir
  defmodule MyApp.Repo.Migrations.UpgradeForjaV2 do
    use Ecto.Migration

    def up, do: Forja.Migration.up(version: 2)
    def down, do: Forja.Migration.down(version: 1)
  end
  ```

  ## Rollback

  Roll back Forja schema changes to a specific version:

  ```elixir
  defmodule MyApp.Repo.Migrations.RollbackForjaToV1 do
    use Ecto.Migration

    def up, do: Forja.Migration.down(version: 1)
    def down, do: Forja.Migration.up(version: 2)
  end
  ```

  ## Version Matrix

  | Forja Version | Migration Version | Changes |
  |---------------|-------------------|---------|
  | 0.5.0 | 1 | Initial schema: `forja_events` table with all columns and indexes |

  ## Maintainer Guide: Adding A New Migration Version

  1. Create a new version module, for example
     `lib/forja/migrations/postgres/v02.ex`, implementing `up/1` and `down/1`.
  2. Bump `@current_version` in `Forja.Migrations.Postgres`.
  3. Add integration tests that validate upgrade and rollback behavior.
  4. Update this version matrix with the new Forja release and migration version.
  5. Add a changelog entry including the exact migration snippet users must run.
  """

  alias Forja.Migrations.Postgres

  @doc """
  Migrates Forja schema forward to the target version.

  This function is intended to be called from inside `use Ecto.Migration`.
  If `:version` is not provided, it migrates to `current_version/0`.

  ## Example

  ```elixir
  defmodule MyApp.Repo.Migrations.UpgradeForjaV1 do
    use Ecto.Migration

    def up, do: Forja.Migration.up(version: 1)
    def down, do: Forja.Migration.down(version: 0)
  end
  ```
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []), do: Postgres.up(opts)

  @doc """
  Migrates Forja schema backward to the target version.

  This function is intended to be called from inside `use Ecto.Migration`.
  If `:version` is not provided, it rolls back all Forja versions to `0`.

  ## Example

  ```elixir
  defmodule MyApp.Repo.Migrations.RollbackForjaToV0 do
    use Ecto.Migration

    def up, do: Forja.Migration.down(version: 0)
    def down, do: Forja.Migration.up(version: 1)
  end
  ```
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []), do: Postgres.down(opts)

  @doc """
  Returns the latest migration version supported by this Forja release.

  ## Examples

      iex> is_integer(Forja.Migration.current_version())
      true

      iex> Forja.Migration.current_version() >= 1
      true
  """
  @spec current_version() :: pos_integer()
  def current_version, do: Postgres.current_version()

  @doc """
  Returns the version currently applied in the database.

  Outside an Ecto migration context, pass `repo: YourApp.Repo`.

  ## Example

  ```elixir
  Forja.Migration.migrated_version(repo: MyApp.Repo)
  ```
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []), do: Postgres.migrated_version(opts)
end
