defmodule Forja.Migrations.Postgres.V01 do
  @moduledoc false

  use Ecto.Migration

  @spec up(keyword()) :: :ok
  def up(_opts) do
    create table(:forja_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:type, :string, null: false)
      add(:payload, :map, default: "{}")
      add(:meta, :map, default: "{}")
      add(:source, :string)
      add(:processed_at, :utc_datetime_usec)
      add(:idempotency_key, :string)
      add(:reconciliation_attempts, :integer, default: 0, null: false)
      add(:schema_version, :integer, default: 1, null: false)
      add(:correlation_id, :binary_id)
      add(:causation_id, :binary_id)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:forja_events, [:type]))
    create(index(:forja_events, [:source]))
    create(index(:forja_events, [:inserted_at]))
    create(index(:forja_events, [:type, :source]))

    create(
      index(:forja_events, [:processed_at],
        where: "processed_at IS NULL",
        name: :forja_events_unprocessed
      )
    )

    create(
      unique_index(:forja_events, [:idempotency_key],
        where: "idempotency_key IS NOT NULL",
        name: :forja_events_idempotency_key_index
      )
    )

    create(
      index(:forja_events, [:processed_at, :inserted_at, :reconciliation_attempts],
        where: "processed_at IS NULL",
        name: :forja_events_reconciliation
      )
    )

    create(
      index(:forja_events, [:correlation_id],
        where: "correlation_id IS NOT NULL",
        name: :forja_events_correlation_id
      )
    )

    create(
      index(:forja_events, [:causation_id],
        where: "causation_id IS NOT NULL",
        name: :forja_events_causation_id
      )
    )
  end

  @spec down(keyword()) :: :ok
  def down(_opts) do
    drop_if_exists(table(:forja_events))
  end
end
