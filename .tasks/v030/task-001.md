# Task 001: Telemetry — Remove Dead Code, Refactor Signatures

**Wave**: 0 | **Effort**: M
**Depends on**: none
**Blocks**: task-004, task-006

## Objective

Remove telemetry events and functions for GenStage (`emit_skipped/3`, `emit_buffer_size/2`) and refactor `emit_emitted`, `emit_processed`, `emit_failed` from 5-positional-param to 2-param (name + map) to eliminate argument-order bugs.

## Files

**Modify:** `lib/forja/telemetry.ex` — remove dead events/functions, refactor signatures
**Modify:** `test/forja/telemetry_test.exs` — update all call sites in both `TelemetryTest` and `DefaultLoggerTest`

## Requirements

### Removals in `lib/forja/telemetry.ex`

1. From `@all_event_names`: remove `[:forja, :event, :skipped]` and `[:forja, :producer, :buffer_size]`
2. From `@event_levels`: remove `:skipped` and `:buffer_size` entries
3. From `@level_tiers` `:debug` list: remove `:skipped` and `:buffer_size`
4. Remove `handle_event` clause for `[:forja, :event, :skipped]` (line ~230)
5. Remove `handle_event` clause for `[:forja, :producer, :buffer_size]` (line ~301)
6. Remove `emit_skipped/3` function (line ~354)
7. Remove `emit_buffer_size/2` function (line ~366)
8. Remove `category_for([:forja, :producer, :buffer_size])` clause (line ~468)

### Refactored signatures

```elixir
# emit_emitted: was (name, type, source, payload \\ nil, correlation_id \\ nil)
@spec emit_emitted(atom(), map()) :: :ok
def emit_emitted(name, %{type: type} = attrs) do
  meta = %{name: name, type: type, source: attrs[:source], correlation_id: attrs[:correlation_id]}
  meta = if attrs[:payload], do: Map.put(meta, :payload, attrs.payload), else: meta
  :telemetry.execute([:forja, :event, :emitted], %{count: 1}, meta)
end

# emit_processed: was (name, type, handler, path, duration)
@spec emit_processed(atom(), map()) :: :ok
def emit_processed(name, %{type: type, handler: handler, path: path, duration: duration}) do
  :telemetry.execute([:forja, :event, :processed], %{duration: duration},
    %{name: name, type: type, handler: handler, path: path})
end

# emit_failed: was (name, type, handler, path, reason)
@spec emit_failed(atom(), map()) :: :ok
def emit_failed(name, %{type: type, handler: handler, path: path, reason: reason}) do
  :telemetry.execute([:forja, :event, :failed], %{count: 1},
    %{name: name, type: type, handler: handler, path: path, reason: reason})
end
```

### Test updates in `test/forja/telemetry_test.exs`

**`Forja.TelemetryTest`:**
- Remove `[:forja, :event, :skipped]` and `[:forja, :producer, :buffer_size]` from setup `attach_many`
- Update `emit_emitted` tests to use `emit_emitted(:test, %{type: ..., source: ...})`
- Update `emit_processed` test to use map arg
- Update `emit_failed` test to use map arg
- Delete `emit_skipped/3` test and `emit_buffer_size/2` test

**`Forja.Telemetry.DefaultLoggerTest` (line 116+):**
- Replace all `Telemetry.emit_emitted(:my_app, "order:created", "orders")` with `Telemetry.emit_emitted(:my_app, %{type: "order:created", source: "orders"})`
- Replace all `emit_emitted` 4-arg calls (with payload) similarly
- Replace all `emit_processed` 5-arg calls with 2-arg map
- Replace all `emit_failed` 5-arg calls with 2-arg map
- Remove `emit_skipped` calls from "level: :debug includes skipped" and "level: :info does NOT include skipped" tests. Remove "Event skipped" assertions.

Update `@moduledoc` to reflect new signatures and removed events.

## Done when

- [ ] `mix test test/forja/telemetry_test.exs` passes
- [ ] `emit_skipped/3` and `emit_buffer_size/2` functions no longer exist
- [ ] `emit_emitted/2`, `emit_processed/2`, `emit_failed/2` accept map as 2nd arg
- [ ] No references to `:skipped` or `:buffer_size` in telemetry module
- [ ] Committed
