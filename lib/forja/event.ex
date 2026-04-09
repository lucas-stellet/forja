defmodule Forja.Event do
  @moduledoc """
  Ecto schema for events persisted in the `forja_events` table.

  Events are the core data model in Forja — they represent domain events
  that flow through the Oban-backed processing pipeline with PubSub notifications.

  ## Fields

  - `id` - UUID binary primary key (auto-generated)
  - `type` - String identifier for the event type (required)
  - `payload` - Map containing the event data (default: `%{}`)
  - `meta` - Map containing event metadata (default: `%{}`)
  - `source` - String identifying the event source
  - `processed_at` - UTC datetime when the event was processed
  - `idempotency_key` - Unique key for idempotent event handling
  - `reconciliation_attempts` - Number of reconciliation attempts (default: 0)
  - `schema_version` - Integer identifying the event schema version (default: 1)
  - `correlation_id` - UUID grouping all events in the same logical transaction
  - `causation_id` - UUID of the event that directly caused this event
  - `inserted_at` - UTC datetime when the event was created (auto-managed)

  ## Examples

      iex> %Forja.Event{type: "user.created", payload: %{"user_id" => 123}}
      %Forja.Event{type: "user.created", payload: %{"user_id" => 123}, ...}
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "forja_events" do
    field(:type, :string)
    field(:payload, :map, default: %{})
    field(:meta, :map, default: %{})
    field(:source, :string)
    field(:processed_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:reconciliation_attempts, :integer, default: 0)
    field(:schema_version, :integer, default: 1)
    field(:correlation_id, :binary_id)
    field(:causation_id, :binary_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: binary(),
          type: String.t() | nil,
          payload: map(),
          meta: map(),
          source: String.t() | nil,
          processed_at: DateTime.t() | nil,
          idempotency_key: String.t() | nil,
          reconciliation_attempts: integer(),
          schema_version: pos_integer(),
          correlation_id: binary() | nil,
          causation_id: binary() | nil,
          inserted_at: DateTime.t()
        }

  @doc """
  Creates a changeset for the given event with the given attributes.

  Required fields: `:type`
  Optional fields: `:payload`, `:meta`, `:source`, `:idempotency_key`, `:schema_version`, `:correlation_id`, `:causation_id`

  ## Examples

      iex> changeset(%Forja.Event{}, %{type: "user.created"})
      #Ecto.Changeset<...>

      iex> changeset(%Forja.Event{}, %{type: ""})
      #Ecto.Changeset<errors: [type: {"can't be blank", ...}]>
  """
  @spec changeset(t() | Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> Ecto.Changeset.cast(attrs, [
      :type,
      :payload,
      :meta,
      :source,
      :idempotency_key,
      :schema_version,
      :correlation_id,
      :causation_id
    ])
    |> Ecto.Changeset.validate_required([:type])
    |> Ecto.Changeset.validate_length(:type, min: 1, max: 255)
    |> Ecto.Changeset.unique_constraint(:idempotency_key)
  end

  @doc """
  Creates a changeset that marks the event as processed by setting `processed_at`.

  ## Examples

      iex> event = %Forja.Event{type: "user.created"}
      iex> mark_processed_changeset(event)
      #Ecto.Changeset<changes: %{processed_at: ~U[2024-01-01 00:00:00Z]}>
  """
  @spec mark_processed_changeset(t() | Ecto.Schema.t()) :: Ecto.Changeset.t()
  def mark_processed_changeset(event) do
    Ecto.Changeset.change(event, processed_at: DateTime.utc_now())
  end

  @doc """
  Creates a changeset that increments the `reconciliation_attempts` counter.

  ## Examples

      iex> event = %Forja.Event{reconciliation_attempts: 0}
      iex> increment_reconciliation_changeset(event)
      #Ecto.Changeset<changes: %{reconciliation_attempts: 1}>
  """
  @spec increment_reconciliation_changeset(t() | Ecto.Schema.t()) :: Ecto.Changeset.t()
  def increment_reconciliation_changeset(event) do
    current = event.reconciliation_attempts || 0
    Ecto.Changeset.change(event, reconciliation_attempts: current + 1)
  end
end
