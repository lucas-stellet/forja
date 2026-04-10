defmodule Forja.Migration do
  @moduledoc """
  Versioned migrations for Forja's database schema.

  ## Usage

  Generate an Ecto migration and delegate to this module:

      defmodule MyApp.Repo.Migrations.SetupForja do
        use Ecto.Migration

        def up, do: Forja.Migration.up()
        def down, do: Forja.Migration.down()
      end

  ## Upgrading

  To upgrade to a specific version:

      defmodule MyApp.Repo.Migrations.UpgradeForjaV2 do
        use Ecto.Migration

        def up, do: Forja.Migration.up(version: 2)
        def down, do: Forja.Migration.down(version: 1)
      end
  """

  alias Forja.Migrations.Postgres

  @spec up(keyword()) :: :ok
  def up(opts \\ []), do: Postgres.up(opts)

  @spec down(keyword()) :: :ok
  def down(opts \\ []), do: Postgres.down(opts)

  @spec current_version() :: pos_integer()
  def current_version, do: Postgres.current_version()

  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []), do: Postgres.migrated_version(opts)
end
