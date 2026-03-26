defmodule Forja.TestRepo.Migrations.AddCorrelationToForjaEvents do
  use Ecto.Migration

  def change do
    alter table(:forja_events) do
      add :correlation_id, :binary_id
      add :causation_id, :binary_id
    end

    create index(:forja_events, [:correlation_id],
             where: "correlation_id IS NOT NULL",
             name: :forja_events_correlation_id
           )

    create index(:forja_events, [:causation_id],
             where: "causation_id IS NOT NULL",
             name: :forja_events_causation_id
           )
  end
end
