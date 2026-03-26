defmodule Forja.Telemetry do
  @moduledoc """
  Telemetry event emission for Forja.

  All events follow the `[:forja, resource, action]` convention and are
  emitted via `:telemetry.execute/3`.

  ## Attaching handlers

      :telemetry.attach_many(
        "forja-metrics",
        [
          [:forja, :event, :emitted],
          [:forja, :event, :processed],
          [:forja, :event, :failed]
        ],
        &MyApp.Metrics.handle_forja_event/4,
        nil
      )

  ## Emitted events

    * `[:forja, :event, :emitted]` - When an event is persisted and emitted
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, type: string, source: string}`

    * `[:forja, :event, :processed]` - When a handler processes successfully
      * Measurements: `%{duration: native_time}`
      * Metadata: `%{name: atom, type: string, handler: module, path: :genstage | :oban}`

    * `[:forja, :event, :failed]` - When a handler fails
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, type: string, handler: module, path: atom, reason: term}`

    * `[:forja, :event, :skipped]` - When the advisory lock was already held
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary, path: atom}`

    * `[:forja, :event, :dead_letter]` - When Oban discards a job (all attempts exhausted)
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary, reason: term}`

    * `[:forja, :event, :abandoned]` - When reconciliation also exhausts its retries
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary, reconciliation_attempts: integer}`

    * `[:forja, :event, :reconciled]` - When reconciliation successfully processes an event
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary}`

    * `[:forja, :event, :deduplicated]` - When an idempotency key prevents a duplicate emission
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, idempotency_key: string, existing_event_id: binary}`

    * `[:forja, :producer, :buffer_size]` - Producer buffer size
      * Measurements: `%{size: non_neg_integer}`
      * Metadata: `%{name: atom}`
  """

  @doc """
  Emits a telemetry event for event emission.
  """
  @spec emit_emitted(atom(), String.t(), String.t() | nil) :: :ok
  def emit_emitted(name, type, source) do
    :telemetry.execute(
      [:forja, :event, :emitted],
      %{count: 1},
      %{name: name, type: type, source: source}
    )
  end

  @doc """
  Emits a telemetry event for successful handler processing.
  """
  @spec emit_processed(atom(), String.t(), module(), atom(), integer()) :: :ok
  def emit_processed(name, type, handler, path, duration) do
    :telemetry.execute(
      [:forja, :event, :processed],
      %{duration: duration},
      %{name: name, type: type, handler: handler, path: path}
    )
  end

  @doc """
  Emits a telemetry event for handler failure.
  """
  @spec emit_failed(atom(), String.t(), module(), atom(), term()) :: :ok
  def emit_failed(name, type, handler, path, reason) do
    :telemetry.execute(
      [:forja, :event, :failed],
      %{count: 1},
      %{name: name, type: type, handler: handler, path: path, reason: reason}
    )
  end

  @doc """
  Emits a telemetry event for a skip due to advisory lock.
  """
  @spec emit_skipped(atom(), String.t(), atom()) :: :ok
  def emit_skipped(name, event_id, path) do
    :telemetry.execute(
      [:forja, :event, :skipped],
      %{count: 1},
      %{name: name, event_id: event_id, path: path}
    )
  end

  @doc """
  Emits a telemetry event with the producer buffer size.
  """
  @spec emit_buffer_size(atom(), non_neg_integer()) :: :ok
  def emit_buffer_size(name, size) do
    :telemetry.execute(
      [:forja, :producer, :buffer_size],
      %{size: size},
      %{name: name}
    )
  end

  @doc """
  Emits a telemetry event when Oban discards a job (dead letter).
  """
  @spec emit_dead_letter(atom(), String.t(), term()) :: :ok
  def emit_dead_letter(name, event_id, reason) do
    :telemetry.execute(
      [:forja, :event, :dead_letter],
      %{count: 1},
      %{name: name, event_id: event_id, reason: reason}
    )
  end

  @doc """
  Emits a telemetry event when reconciliation exhausts all retries (abandoned).
  """
  @spec emit_abandoned(atom(), String.t(), non_neg_integer()) :: :ok
  def emit_abandoned(name, event_id, reconciliation_attempts) do
    :telemetry.execute(
      [:forja, :event, :abandoned],
      %{count: 1},
      %{name: name, event_id: event_id, reconciliation_attempts: reconciliation_attempts}
    )
  end

  @doc """
  Emits a telemetry event when reconciliation successfully processes an event.
  """
  @spec emit_reconciled(atom(), String.t()) :: :ok
  def emit_reconciled(name, event_id) do
    :telemetry.execute(
      [:forja, :event, :reconciled],
      %{count: 1},
      %{name: name, event_id: event_id}
    )
  end

  @doc """
  Emits a telemetry event when an idempotency key prevents a duplicate emission.
  """
  @spec emit_deduplicated(atom(), String.t(), String.t()) :: :ok
  def emit_deduplicated(name, idempotency_key, existing_event_id) do
    :telemetry.execute(
      [:forja, :event, :deduplicated],
      %{count: 1},
      %{name: name, idempotency_key: idempotency_key, existing_event_id: existing_event_id}
    )
  end
end
