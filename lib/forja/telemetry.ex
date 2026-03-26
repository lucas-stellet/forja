defmodule Forja.Telemetry do
  @moduledoc """
  Telemetry event emission and default logger for Forja.

  All events follow the `[:forja, resource, action]` convention and are
  emitted via `:telemetry.execute/3`.

  ## Default Logger

  Forja ships with an opt-in default logger that converts telemetry events
  into structured `Logger` calls. Activate it in your `application.ex`:

      Forja.Telemetry.attach_default_logger(level: :info)

  The `:level` option controls which categories of events are logged:

  | Level      | Events logged                                                     |
  |------------|-------------------------------------------------------------------|
  | `:debug`   | All events (emitted, processed, skipped, deduplicated, reconciled, failed, validation_failed, dead_letter, abandoned) |
  | `:info`    | Lifecycle + problems (emitted, processed, reconciled, failed, validation_failed, dead_letter, abandoned) |
  | `:warning` | Problems only (failed, validation_failed, dead_letter, abandoned) |
  | `:error`   | Critical only (dead_letter, abandoned)                            |

  ### Options

    * `:level` - Logger level tier (default: `:info`)
    * `:include_payload` - Include event payload in logs (default: `false`)
    * `:encode` - JSON-encode log output (default: `false`)
    * `:events` - `:all` (default) or explicit list like `[:emitted, :processed]`

  ### Example

      # Development: see everything including payloads
      Forja.Telemetry.attach_default_logger(level: :debug, include_payload: true)

      # Production: only problems
      Forja.Telemetry.attach_default_logger(level: :warning, encode: true)

  All log calls use `domain: [:forja]`, so you can filter them:

      # Suppress all Forja logs via Erlang logger filters
      :logger.add_primary_filter(:no_forja, {&:logger_filters.domain/2, {:stop, :sub, [:forja]}})

  ## Emitted events

    * `[:forja, :event, :emitted]` - When an event is persisted and emitted
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, type: string, source: string, payload: map | nil}`

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

    * `[:forja, :event, :validation_failed]` - When payload validation fails at emit-time
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, type: string | module, errors: term}`

    * `[:forja, :producer, :buffer_size]` - Producer buffer size
      * Measurements: `%{size: non_neg_integer}`
      * Metadata: `%{name: atom}`
  """

  require Logger

  @handler_id "forja-default-logger"

  @all_event_names [
    [:forja, :event, :emitted],
    [:forja, :event, :processed],
    [:forja, :event, :failed],
    [:forja, :event, :skipped],
    [:forja, :event, :dead_letter],
    [:forja, :event, :abandoned],
    [:forja, :event, :reconciled],
    [:forja, :event, :deduplicated],
    [:forja, :event, :validation_failed],
    [:forja, :producer, :buffer_size]
  ]

  # Maps each event category to the Logger level it emits at
  @event_levels %{
    emitted: :info,
    processed: :info,
    reconciled: :info,
    skipped: :debug,
    deduplicated: :debug,
    buffer_size: :debug,
    failed: :warning,
    dead_letter: :error,
    abandoned: :error,
    validation_failed: :warning
  }

  # Which event categories are included at each tier level
  @level_tiers %{
    debug: Map.keys(@event_levels),
    info: [
      :emitted,
      :processed,
      :reconciled,
      :failed,
      :dead_letter,
      :abandoned,
      :validation_failed
    ],
    warning: [:failed, :dead_letter, :abandoned, :validation_failed],
    error: [:dead_letter, :abandoned]
  }

  # ── Default Logger API ──────────────────────────────────────────────

  @doc """
  Returns the telemetry handler ID used by the default logger.
  """
  @spec default_handler_id() :: String.t()
  def default_handler_id, do: @handler_id

  @doc """
  Attaches the default logger that converts Forja telemetry events into
  structured `Logger` calls with `domain: [:forja]`.

  ## Options

    * `:level` - Controls which event categories are logged. One of
      `:debug`, `:info`, `:warning`, `:error`. Default: `:info`.
    * `:include_payload` - When `true`, includes the event payload in
      `:emitted` log entries. Default: `false`.
    * `:encode` - When `true`, JSON-encodes the log output. Default: `false`.
    * `:events` - `:all` to use the level tier (default), or an explicit
      list of category atoms like `[:emitted, :processed, :failed]`.
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    opts =
      Keyword.validate!(opts,
        level: :info,
        encode: false,
        include_payload: false,
        events: :all
      )

    events = resolve_events(opts[:events], opts[:level])
    event_names = categories_to_event_names(events)

    :telemetry.attach_many(@handler_id, event_names, &__MODULE__.handle_event/4, opts)
  end

  @doc """
  Detaches the default logger.
  """
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event([:forja, :event, :emitted], _measurements, meta, opts) do
    log(opts, @event_levels.emitted, fn ->
      base = %{
        message: "Event emitted",
        event: "event:emitted",
        name: to_string(meta.name),
        type: meta.type,
        event_source: meta[:source]
      }

      if opts[:include_payload] && meta[:payload] do
        Map.put(base, :payload, meta.payload)
      else
        base
      end
    end)
  end

  def handle_event([:forja, :event, :processed], measurements, meta, opts) do
    duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)

    log(opts, @event_levels.processed, fn ->
      %{
        message: "Event processed",
        event: "event:processed",
        name: to_string(meta.name),
        type: meta.type,
        handler: inspect(meta.handler),
        path: to_string(meta.path),
        duration_us: duration_us
      }
    end)
  end

  def handle_event([:forja, :event, :failed], _measurements, meta, opts) do
    log(opts, @event_levels.failed, fn ->
      %{
        message: "Handler failed",
        event: "event:failed",
        name: to_string(meta.name),
        type: meta.type,
        handler: inspect(meta.handler),
        path: to_string(meta.path),
        reason: inspect(meta.reason)
      }
    end)
  end

  def handle_event([:forja, :event, :skipped], _measurements, meta, opts) do
    log(opts, @event_levels.skipped, fn ->
      %{
        message: "Event skipped (locked)",
        event: "event:skipped",
        name: to_string(meta.name),
        event_id: meta.event_id,
        path: to_string(meta.path)
      }
    end)
  end

  def handle_event([:forja, :event, :dead_letter], _measurements, meta, opts) do
    log(opts, @event_levels.dead_letter, fn ->
      %{
        message: "Event dead-lettered",
        event: "event:dead_letter",
        name: to_string(meta.name),
        event_id: meta.event_id,
        reason: inspect(meta.reason)
      }
    end)
  end

  def handle_event([:forja, :event, :abandoned], _measurements, meta, opts) do
    log(opts, @event_levels.abandoned, fn ->
      %{
        message: "Event abandoned",
        event: "event:abandoned",
        name: to_string(meta.name),
        event_id: meta.event_id,
        reconciliation_attempts: meta.reconciliation_attempts
      }
    end)
  end

  def handle_event([:forja, :event, :reconciled], _measurements, meta, opts) do
    log(opts, @event_levels.reconciled, fn ->
      %{
        message: "Event reconciled",
        event: "event:reconciled",
        name: to_string(meta.name),
        event_id: meta.event_id
      }
    end)
  end

  def handle_event([:forja, :event, :deduplicated], _measurements, meta, opts) do
    log(opts, @event_levels.deduplicated, fn ->
      %{
        message: "Event deduplicated",
        event: "event:deduplicated",
        name: to_string(meta.name),
        idempotency_key: meta.idempotency_key,
        existing_event_id: meta.existing_event_id
      }
    end)
  end

  def handle_event([:forja, :event, :validation_failed], _measurements, meta, opts) do
    log(opts, @event_levels.validation_failed, fn ->
      %{
        message: "Event validation failed",
        event: "event:validation_failed",
        name: to_string(meta.name),
        type: inspect(meta.type),
        errors: inspect(meta.errors)
      }
    end)
  end

  def handle_event([:forja, :producer, :buffer_size], measurements, meta, opts) do
    log(opts, @event_levels.buffer_size, fn ->
      %{
        message: "Producer buffer",
        event: "producer:buffer_size",
        name: to_string(meta.name),
        size: measurements.size
      }
    end)
  end

  def handle_event(_event, _measurements, _meta, _opts), do: :ok

  # ── Telemetry Emission Functions ────────────────────────────────────

  @doc """
  Emits a telemetry event for event emission.
  """
  @spec emit_emitted(atom(), String.t(), String.t() | nil, map() | nil) :: :ok
  def emit_emitted(name, type, source, payload \\ nil) do
    meta = %{name: name, type: type, source: source}
    meta = if payload, do: Map.put(meta, :payload, payload), else: meta

    :telemetry.execute([:forja, :event, :emitted], %{count: 1}, meta)
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

  @doc """
  Emits a telemetry event when payload validation fails at emit-time.
  """
  @spec emit_validation_failed(atom(), String.t() | module(), [map()]) :: :ok
  def emit_validation_failed(name, type, errors) do
    :telemetry.execute(
      [:forja, :event, :validation_failed],
      %{count: 1},
      %{name: name, type: type, errors: errors}
    )
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp log(opts, level, fun) do
    Logger.log(
      level,
      fn ->
        output = Map.put(fun.(), :source, "forja")

        if Keyword.fetch!(opts, :encode) do
          Jason.encode_to_iodata!(output)
        else
          output
        end
      end,
      domain: [:forja]
    )
  end

  defp resolve_events(:all, level) do
    Map.fetch!(@level_tiers, level)
  end

  defp resolve_events(events, _level) when is_list(events), do: events

  defp categories_to_event_names(categories) do
    category_set = MapSet.new(categories)

    Enum.filter(@all_event_names, fn event_name ->
      category_for(event_name) in category_set
    end)
  end

  defp category_for([:forja, :event, action]), do: action
  defp category_for([:forja, :producer, :buffer_size]), do: :buffer_size
end
