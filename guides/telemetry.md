# Telemetry

Forja emits telemetry events via `:telemetry.execute/3` for observability. All events follow the `[:forja, resource, action]` naming convention.

## Events reference

### `[:forja, :event, :emitted]`

Emitted when an event is persisted and broadcast.

- **Measurements:** `%{count: 1}`
- **Metadata:** `%{name: atom, type: string, source: string}`

### `[:forja, :event, :processed]`

Emitted when a handler processes an event successfully.

- **Measurements:** `%{duration: native_time}`
- **Metadata:** `%{name: atom, type: string, handler: module, path: :genstage | :oban | :reconciliation | :inline}`

### `[:forja, :event, :failed]`

Emitted when a handler returns `{:error, reason}` or raises an exception.

- **Measurements:** `%{count: 1}`
- **Metadata:** `%{name: atom, type: string, handler: module, path: atom, reason: term}`

### `[:forja, :event, :skipped]`

Emitted when the advisory lock is already held by another processing path.

- **Measurements:** `%{count: 1}`
- **Metadata:** `%{name: atom, event_id: binary, path: atom}`

### `[:forja, :event, :dead_letter]`

Emitted when Oban discards a `ProcessEventWorker` job (all retry attempts exhausted).

- **Measurements:** `%{count: 1}`
- **Metadata:** `%{name: atom, event_id: binary, reason: term}`

### `[:forja, :event, :abandoned]`

Emitted when the reconciliation worker exhausts its retry limit for an event.

- **Measurements:** `%{count: 1}`
- **Metadata:** `%{name: atom, event_id: binary, reconciliation_attempts: integer}`

### `[:forja, :event, :reconciled]`

Emitted when the reconciliation worker successfully processes a stale event.

- **Measurements:** `%{count: 1}`
- **Metadata:** `%{name: atom, event_id: binary}`

### `[:forja, :event, :deduplicated]`

Emitted when an idempotency key prevents a duplicate event emission.

- **Measurements:** `%{count: 1}`
- **Metadata:** `%{name: atom, idempotency_key: string, existing_event_id: binary}`

### `[:forja, :producer, :buffer_size]`

Emitted with the GenStage producer buffer size.

- **Measurements:** `%{size: non_neg_integer}`
- **Metadata:** `%{name: atom}`

## Default Logger

Forja ships with an opt-in default logger that converts telemetry events into structured `Logger` calls. Add it to your `application.ex`:

```elixir
def start(_type, _args) do
  Forja.Telemetry.attach_default_logger(level: :info)

  children = [
    # ...
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `:level` | `:info` | Controls which categories of events are logged (see tiers below) |
| `:include_payload` | `false` | Include event payload in `:emitted` log entries |
| `:encode` | `false` | JSON-encode the log output |
| `:events` | `:all` | `:all` (uses level tier) or explicit list like `[:emitted, :failed]` |

### Level Tiers

The `:level` option determines which event categories are logged:

| Level | Events logged |
|-------|---------------|
| `:debug` | All events (emitted, processed, skipped, deduplicated, reconciled, failed, dead_letter, abandoned) |
| `:info` | Lifecycle + problems (emitted, processed, reconciled, failed, dead_letter, abandoned) |
| `:warning` | Problems only (failed, dead_letter, abandoned) |
| `:error` | Critical only (dead_letter, abandoned) |

Each event is logged at a Logger level matching its severity: `:info` for lifecycle events, `:debug` for internal details, `:warning` for failures, `:error` for critical issues.

### Examples

```elixir
# Development: see everything including event payloads
Forja.Telemetry.attach_default_logger(level: :debug, include_payload: true)

# Production: only problems, JSON-encoded
Forja.Telemetry.attach_default_logger(level: :warning, encode: true)

# Custom: only specific event categories
Forja.Telemetry.attach_default_logger(events: [:emitted, :failed, :dead_letter])
```

### Detaching

```elixir
Forja.Telemetry.detach_default_logger()
```

### Filtering via Logger domain

All log calls use `domain: [:forja]`, enabling Erlang logger filters:

```elixir
# Suppress all Forja logs
:logger.add_primary_filter(:no_forja, {&:logger_filters.domain/2, {:stop, :sub, [:forja]}})
```

## Attaching custom handlers

```elixir
:telemetry.attach_many(
  "forja-metrics",
  [
    [:forja, :event, :emitted],
    [:forja, :event, :processed],
    [:forja, :event, :failed],
    [:forja, :event, :dead_letter]
  ],
  &MyApp.ForjaMetrics.handle_event/4,
  nil
)
```

## Example: StatsD metrics

```elixir
defmodule MyApp.ForjaMetrics do
  def handle_event([:forja, :event, :emitted], _measurements, metadata, _config) do
    StatsD.increment("forja.events.emitted", tags: ["type:#{metadata.type}"])
  end

  def handle_event([:forja, :event, :processed], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    StatsD.histogram("forja.events.duration_ms", duration_ms, tags: [
      "type:#{metadata.type}",
      "path:#{metadata.path}",
      "handler:#{inspect(metadata.handler)}"
    ])
  end

  def handle_event([:forja, :event, :failed], _measurements, metadata, _config) do
    StatsD.increment("forja.events.failed", tags: [
      "type:#{metadata.type}",
      "handler:#{inspect(metadata.handler)}"
    ])
  end

  def handle_event([:forja, :event, :dead_letter], _measurements, metadata, _config) do
    StatsD.increment("forja.events.dead_letter", tags: [
      "event_id:#{metadata.event_id}"
    ])
  end
end
```

## Example: Custom Logger

If you need more control than the default logger provides, attach your own handler:

```elixir
:telemetry.attach(
  "forja-custom-logger",
  [:forja, :event, :dead_letter],
  fn _event, _measurements, metadata, _config ->
    require Logger
    Logger.error("Forja dead letter: event #{metadata.event_id}, reason: #{inspect(metadata.reason)}")
  end,
  nil
)
```
