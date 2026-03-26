defmodule Forja.TestRepo.Migrations.AddSchemaVersionToForjaEvents do
  use Ecto.Migration

  def change do
    alter table(:forja_events) do
      add :schema_version, :integer, default: 1, null: false
    end
  end
end
