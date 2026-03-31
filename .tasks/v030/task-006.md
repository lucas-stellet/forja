# Task 006: Main Module — Remove GenStage, Add transaction/2 and broadcast_event/2

**Wave**: 2 | **Effort**: L
**Depends on**: task-001, task-002, task-003, task-004
**Blocks**: task-007, task-008

## Objective

Major rewrite of `lib/forja.ex`: remove GenStage from supervision tree, remove `notify_producers/2`, add `safe_broadcast`, add `Forja.transaction/2` and `Forja.broadcast_event/2`, and thread queue routing from schema into Oban job insertion.

## Files

**Modify:** `lib/forja.ex` — supervision tree, emit flow, new public functions
**Modify:** `test/forja_test.exs` — add broadcast, transaction, broadcast_event tests
**Read:** `lib/forja/config.ex` — uses `default_queue` from task-002
**Read:** `lib/forja/event/schema.ex` — uses `queue/0` from task-003
**Read:** `lib/forja/telemetry.ex` — uses `emit_emitted/2` map signature from task-001

## Requirements

### Supervision tree

Remove `EventProducer` and `EventConsumer` from `init/1` children. Only keep `ObanListener`. Remove aliases for `EventConsumer`, `EventProducer`.

### `resolve_event_type/2`

Return 5-tuple adding `schema_module`:

```elixir
{:ok, schema_module.event_type(), string_keyed, schema_module.schema_version(), schema_module}
```

### `emit/3`

Update pattern match for 5-tuple. Pass `schema_module` to `do_emit/4`:

```elixir
case resolve_event_type(type, opts) do
  {:ok, resolved_type, payload, schema_version, schema_module} ->
    # ... build attrs ...
    do_emit(config, name, attrs, schema_module)
```

### `do_emit/4`

Add queue routing:

```elixir
defp do_emit(config, name, attrs, schema_module) do
  queue = resolve_queue(config, schema_module)
  # ... Multi with:
  changeset = ProcessEventWorker.new(job_args, queue: :"forja_#{queue}")
```

### `emit_multi/4`

1. Update `resolve_event_type` pattern match from 4-tuple to 5-tuple: `{:ok, resolved_type, validated_payload, schema_version, _schema_module} ->`
2. Add queue routing in Oban job step. **Bind `config` explicitly inside the closure:**

```elixir
%Event{} = event ->
  config = Config.get(name)
  queue = resolve_queue(config, type)
  job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
  changeset = ProcessEventWorker.new(job_args, queue: :"forja_#{queue}")
  Oban.insert(config.oban_name, changeset)
```

3. Update `@doc` — remove GenStage fast-path section, replace `notify_producers` example with `Forja.transaction/2`

### `resolve_queue/2` (new private function)

```elixir
defp resolve_queue(config, schema_module) do
  if function_exported?(schema_module, :queue, 0) and schema_module.queue() != nil do
    schema_module.queue()
  else
    config.default_queue
  end
end
```

### `after_emit/3` + `safe_broadcast/3`

Replace `notify_producers` call with `safe_broadcast`:

```elixir
defp after_emit(config, _name, event) do
  safe_broadcast(config, event, :forja_event_emitted)
end

defp safe_broadcast(config, event, tag) do
  topic = "#{config.event_topic_prefix}:events"
  Phoenix.PubSub.broadcast(config.pubsub, topic, {tag, event})
rescue
  error ->
    Logger.warning("Forja: PubSub broadcast failed: #{inspect(error)}", domain: [:forja])
    :ok
end
```

### Remove `notify_producers/2`

Delete the function entirely.

### `Forja.transaction/2` (new public function)

```elixir
@spec transaction(Ecto.Multi.t(), atom()) :: {:ok, map()} | {:error, atom(), term(), map()}
def transaction(multi, name) do
  config = Config.get(name)
  case config.repo.transaction(multi) do
    {:ok, results} ->
      Enum.each(results, fn
        {key, %Event{} = event} when is_atom(key) ->
          if key |> Atom.to_string() |> String.starts_with?("forja_event_") do
            safe_broadcast(config, event, :forja_event_emitted)
          end
        _ -> :ok
      end)
      {:ok, results}
    error -> error
  end
end
```

### `Forja.broadcast_event/2` (new public function)

```elixir
@spec broadcast_event(atom(), String.t()) :: :ok | {:error, :not_found}
def broadcast_event(name, event_id) do
  config = Config.get(name)
  case config.repo.get(Event, event_id) do
    nil -> {:error, :not_found}
    %Event{} = event ->
      safe_broadcast(config, event, :forja_event_emitted)
      :ok
  end
end
```

### Telemetry call update

Update `do_emit` to use new map signature:

```elixir
Telemetry.emit_emitted(name, %{type: attrs.type, source: attrs.source, payload: attrs.payload, correlation_id: attrs.correlation_id})
```

### `@moduledoc` update

- Replace "dual-path processing" with "Oban-backed processing"
- Remove "PubSub/GenStage latency with Oban delivery guarantees"
- Remove "three-layer deduplication" — replace with "Oban unique constraint + processed_at safety net"
- Add `transaction/2` usage example

### Tests

Subscribe to PubSub in setup. Add tests for:
- `emit/3` broadcasts `:forja_event_emitted`
- `transaction/2` executes multi and broadcasts
- `transaction/2` returns error on failure
- `broadcast_event/2` loads and broadcasts
- `broadcast_event/2` returns error for non-existent event

See plan Task 6 Step 1 for exact test code.

## Done when

- [ ] `mix test test/forja_test.exs` passes
- [ ] GenStage removed from supervision tree
- [ ] `notify_producers/2` deleted
- [ ] `transaction/2` works with auto-broadcast
- [ ] `broadcast_event/2` works
- [ ] Queue routing threads from schema to Oban job
- [ ] PubSub broadcasts use `safe_broadcast` (try/rescue)
- [ ] Committed
