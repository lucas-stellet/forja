defmodule CreateForjaEvents do
  use Ecto.Migration

  def change do
    create table(:forja_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :payload, :map, default: "{}"
      add :meta, :map, default: "{}"
      add :source, :string
      add :processed_at, :utc_datetime_usec
      add :idempotency_key, :string
      add :reconciliation_attempts, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:forja_events, [:type])
    create index(:forja_events, [:source])
    create index(:forja_events, [:inserted_at])
    create index(:forja_events, [:type, :source])

    create index(:forja_events, [:processed_at],
             where: "processed_at IS NULL",
             name: :forja_events_unprocessed
           )

    create unique_index(:forja_events, [:idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :forja_events_idempotency_key_index
           )

    create index(:forja_events, [:processed_at, :inserted_at, :reconciliation_attempts],
             where: "processed_at IS NULL",
             name: :forja_events_reconciliation
           )
  end
end
