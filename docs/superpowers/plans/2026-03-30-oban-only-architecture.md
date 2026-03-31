# Forja v0.3.0 Oban-Only Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Forja from dual-path (GenStage + Oban) to Oban-only event processing, with PubSub as a notification channel.

**Architecture:** Remove GenStage and advisory locks. Oban becomes the sole processing path. PubSub broadcasts event notifications post-emit and post-processing. New `queue` macro in event schemas for per-event queue routing. New `Forja.transaction/2` wraps `emit_multi` workflows with automatic broadcast.

**Tech Stack:** Elixir, Oban (free), Phoenix.PubSub, Ecto, PostgreSQL

**Spec:** `docs/superpowers/specs/2026-03-30-oban-only-architecture-design.md`

---

## File Map

### Files to Delete

| File | Test File | Reason |
|---|---|---|
| `lib/forja/event_producer.ex` | `test/forja/event_producer_test.exs` | GenStage producer removed |
| `lib/forja/event_consumer.ex` | `test/forja/event_consumer_test.exs` | GenStage consumer removed |
| `lib/forja/event_worker.ex` | — | GenStage task wrapper removed |
| `lib/forja/advisory_lock.ex` | `test/forja/advisory_lock_test.exs` | Advisory locks removed |

### Files to Modify

| File | Changes |
|---|---|
| `lib/forja/telemetry.ex` | Remove `emit_skipped/3`, `emit_buffer_size/2`, skipped/buffer_size handlers and event names. Refactor `emit_emitted/5`, `emit_processed/5`, `emit_failed/5` to accept map as 2nd arg. |
| `lib/forja/processor.ex` | Remove advisory lock wrapper, remove `{:skipped, :locked}`, `dispatch_to_handlers` returns `:ok` always, `mark_processed` uses non-bang `update/1`, add `safe_broadcast` post-processing. |
| `lib/forja/config.ex` | Remove `consumer_pool_size`, add `default_queue`. |
| `lib/forja/event/schema.ex` | Add `queue` macro, generate `queue/0` function. |
| `lib/forja.ex` | Remove GenStage from supervision tree, remove `notify_producers/2`, replace `after_emit` with `safe_broadcast`, add `transaction/2`, add `broadcast_event/2`, thread queue from schema to Oban job insertion in `do_emit` and `emit_multi`. Update version to 0.3.0. |
| `lib/forja/workers/process_event_worker.ex` | Remove `{:skipped, :locked}` clause, update unique period to 900. |
| `lib/forja/workers/reconciliation_worker.ex` | Remove `{:skipped, :locked}` clause, add Oban job existence check before processing. |
| `lib/forja/handler.ex` | Update moduledoc (remove dual-path references). |
| `lib/forja/testing.ex` | Update moduledoc (remove GenStage references). |
| `mix.exs` | Bump version to 0.3.0, remove `gen_stage` dependency, update description. |

### Test Files to Modify

| File | Changes |
|---|---|
| `test/forja/telemetry_test.exs` | Update to new function signatures (map args), remove skipped/buffer_size tests. |
| `test/forja/processor_test.exs` | Replace `:genstage` path with `:oban`, add test for `safe_broadcast`, test `mark_processed` failure returns error. |
| `test/forja/config_test.exs` | Remove `consumer_pool_size` tests, add `default_queue` tests. |
| `test/forja/event/schema_test.exs` | Add `queue` macro tests. |
| `test/forja_test.exs` | Add `transaction/2` tests, add `broadcast_event/2` tests, update `emit_multi` tests. |
| `test/forja/workers/process_event_worker_test.exs` | Remove `{:skipped, :locked}` test coverage. |
| `test/forja/workers/reconciliation_worker_test.exs` | Remove `{:skipped, :locked}` test, add Oban job check test. |

---

## Task 1: Telemetry — Remove Dead Code and Refactor Signatures

**Files:**
- Modify: `lib/forja/telemetry.ex`
- Modify: `test/forja/telemetry_test.exs`

- [ ] **Step 1: Update tests for removed events and new signatures**

Remove tests for `emit_skipped` and `emit_buffer_size`. Update tests for `emit_emitted`, `emit_processed`, `emit_failed` to use map argument:

```elixir
# In test setup, remove :skipped and :buffer_size from attached events:
# Remove: [:forja, :event, :skipped]
# Remove: [:forja, :producer, :buffer_size]

# Update existing tests:
test "emit_emitted/2 sends telemetry event" do
  Telemetry.emit_emitted(:test, %{type: "order:created", source: "orders"})

  assert_receive {:telemetry, [:forja, :event, :emitted], %{count: 1},
                  %{name: :test, type: "order:created", source: "orders"}}
end

test "emit_emitted/2 includes payload when provided" do
  Telemetry.emit_emitted(:test, %{type: "order:created", source: "orders", payload: %{"id" => 1}})

  assert_receive {:telemetry, [:forja, :event, :emitted], %{count: 1},
                  %{name: :test, type: "order:created", payload: %{"id" => 1}}}
end

test "emit_processed/2 sends telemetry event with duration" do
  Telemetry.emit_processed(:test, %{type: "order:created", handler: FakeHandler, path: :oban, duration: 1_000})

  assert_receive {:telemetry, [:forja, :event, :processed], %{duration: 1_000},
                  %{name: :test, type: "order:created", handler: FakeHandler, path: :oban}}
end

test "emit_failed/2 sends telemetry event with reason" do
  Telemetry.emit_failed(:test, %{type: "order:created", handler: FakeHandler, path: :oban, reason: :timeout})

  assert_receive {:telemetry, [:forja, :event, :failed], %{count: 1},
                  %{name: :test, type: "order:created", handler: FakeHandler, path: :oban, reason: :timeout}}
end

# Remove these tests entirely:
# - "emit_skipped/3 sends telemetry event"
# - "emit_buffer_size/2 sends telemetry event"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/telemetry_test.exs`
Expected: FAIL — old function signatures don't match

- [ ] **Step 3: Update Telemetry module**

In `lib/forja/telemetry.ex`:

1. Remove from `@all_event_names`: `[:forja, :event, :skipped]` and `[:forja, :producer, :buffer_size]`
2. Remove from `@event_levels`: `:skipped` and `:buffer_size` entries
3. Remove from `@level_tiers` `:debug` list: `:skipped` and `:buffer_size`
4. Remove `handle_event` clause for `[:forja, :event, :skipped]`
5. Remove `handle_event` clause for `[:forja, :producer, :buffer_size]`
6. Remove `emit_skipped/3` function
7. Remove `emit_buffer_size/2` function
8. Remove `category_for([:forja, :producer, :buffer_size])` clause
9. Refactor `emit_emitted` from 5-param to 2-param (name + map):

```elixir
@spec emit_emitted(atom(), map()) :: :ok
def emit_emitted(name, %{type: type} = attrs) do
  meta = %{name: name, type: type, source: attrs[:source], correlation_id: attrs[:correlation_id]}
  meta = if attrs[:payload], do: Map.put(meta, :payload, attrs.payload), else: meta
  :telemetry.execute([:forja, :event, :emitted], %{count: 1}, meta)
end
```

10. Refactor `emit_processed` from 5-param to 2-param:

```elixir
@spec emit_processed(atom(), map()) :: :ok
def emit_processed(name, %{type: type, handler: handler, path: path, duration: duration}) do
  :telemetry.execute(
    [:forja, :event, :processed],
    %{duration: duration},
    %{name: name, type: type, handler: handler, path: path}
  )
end
```

11. Refactor `emit_failed` from 5-param to 2-param:

```elixir
@spec emit_failed(atom(), map()) :: :ok
def emit_failed(name, %{type: type, handler: handler, path: path, reason: reason}) do
  :telemetry.execute(
    [:forja, :event, :failed],
    %{count: 1},
    %{name: name, type: type, handler: handler, path: path, reason: reason}
  )
end
```

12. Update the default logger `handle_event` for `:emitted` — update `@moduledoc` to reflect new signatures and removed events.

- [ ] **Step 4: Update DefaultLoggerTest calls to new signatures**

In `test/forja/telemetry_test.exs`, the `Forja.Telemetry.DefaultLoggerTest` module (line 116+) calls the old 3-arg and 5-arg signatures. Update all calls:

```elixir
# Replace all occurrences of:
Telemetry.emit_emitted(:my_app, "order:created", "orders")
# With:
Telemetry.emit_emitted(:my_app, %{type: "order:created", source: "orders"})

# Replace all occurrences of:
Telemetry.emit_emitted(:my_app, "order:created", "orders", %{"order_id" => 42})
# With:
Telemetry.emit_emitted(:my_app, %{type: "order:created", source: "orders", payload: %{"order_id" => 42}})

# Replace all occurrences of:
Telemetry.emit_processed(:my_app, "order:created", MyHandler, :oban, 5_000_000)
# With:
Telemetry.emit_processed(:my_app, %{type: "order:created", handler: MyHandler, path: :oban, duration: 5_000_000})

# Replace all occurrences of:
Telemetry.emit_processed(:my_app, "order:created", MyHandler, :oban, 1_000)
# With:
Telemetry.emit_processed(:my_app, %{type: "order:created", handler: MyHandler, path: :oban, duration: 1_000})

# Replace all occurrences of:
Telemetry.emit_failed(:my_app, "order:created", MyHandler, :oban, :timeout)
# With:
Telemetry.emit_failed(:my_app, %{type: "order:created", handler: MyHandler, path: :oban, reason: :timeout})

# Remove tests that call emit_skipped:
# - "level: :debug includes skipped and deduplicated events" — remove emit_skipped call, keep emit_deduplicated
# - "level: :info does NOT include skipped or deduplicated" — remove emit_skipped call, keep emit_deduplicated
# Remove asserts for "Event skipped" in both tests.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/telemetry_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/forja/telemetry.ex test/forja/telemetry_test.exs
git commit -m "refactor: remove dead telemetry events, refactor emission functions to map args"
```

---

## Task 2: Config — Remove `consumer_pool_size`, Add `default_queue`

**Files:**
- Modify: `lib/forja/config.ex`
- Modify: `test/forja/config_test.exs`

- [ ] **Step 1: Update config tests**

In `test/forja/config_test.exs`:

Remove any tests asserting `consumer_pool_size` default or behavior. Add tests for `default_queue`:

```elixir
test "default_queue defaults to :events" do
  config = Config.new(name: :test, repo: Repo, pubsub: PubSub)
  assert config.default_queue == :events
end

test "default_queue can be overridden" do
  config = Config.new(name: :test, repo: Repo, pubsub: PubSub, default_queue: :custom)
  assert config.default_queue == :custom
end

test "consumer_pool_size is not a valid option" do
  # Struct no longer has this field — passing it raises
  assert_raise KeyError, fn ->
    Config.new(name: :test, repo: Repo, pubsub: PubSub, consumer_pool_size: 8)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/config_test.exs`
Expected: FAIL

- [ ] **Step 3: Update Config struct**

In `lib/forja/config.ex`:

1. Remove `consumer_pool_size: 4` from `defstruct`
2. Add `default_queue: :events` to `defstruct`
3. Remove `consumer_pool_size` from `@type t`
4. Add `default_queue: atom()` to `@type t`
5. Update `@moduledoc` — remove `consumer_pool_size` docs, add `default_queue` docs

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/config_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/forja/config.ex test/forja/config_test.exs
git commit -m "refactor: remove consumer_pool_size, add default_queue to Config"
```

---

## Task 3: Event Schema — Add `queue` Macro

**Files:**
- Modify: `lib/forja/event/schema.ex`
- Modify: `test/forja/event/schema_test.exs`

- [ ] **Step 1: Write failing tests for queue macro**

In `test/forja/event/schema_test.exs`, add:

```elixir
defmodule QueuedEvent do
  use Forja.Event.Schema

  event_type "test:queued"
  schema_version 1
  queue :payments

  payload do
    field :id, Zoi.string()
  end
end

defmodule DefaultQueueEvent do
  use Forja.Event.Schema

  event_type "test:default_queue"

  payload do
    field :id, Zoi.string()
  end
end

test "queue/0 returns configured queue name" do
  assert QueuedEvent.queue() == :payments
end

test "queue/0 returns nil when not configured" do
  assert DefaultQueueEvent.queue() == nil
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/event/schema_test.exs`
Expected: FAIL — `queue` macro not defined

- [ ] **Step 3: Implement queue macro**

In `lib/forja/event/schema.ex`:

1. Add `@forja_queue nil` to the `__using__` macro body (after `@forja_payload_used false`)

2. Add the `queue` macro definition after `schema_version`:

```elixir
@doc """
Sets the Oban queue for this event type.

Forja prefixes the name with `forja_` internally. For example,
`queue :payments` routes to the `:forja_payments` Oban queue.

## Example

    queue :payments
"""
defmacro queue(name) when is_atom(name) do
  quote do
    @forja_queue unquote(name)
  end
end
```

3. In `__before_compile__/1`, read the queue attribute and generate the function:

After `def schema_version, do: unquote(version)`, add:

```elixir
queue_value = Module.get_attribute(env.module, :forja_queue)
```

And in the generated `quote` block, add:

```elixir
@doc """
Returns the configured Oban queue name, or `nil` if not set.
"""
def queue, do: unquote(queue_value)
```

4. Update `@moduledoc` generated functions list to include `queue/0`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/event/schema_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/forja/event/schema.ex test/forja/event/schema_test.exs
git commit -m "feat: add queue macro to Event.Schema for per-event queue routing"
```

---

## Task 4: Processor — Remove Advisory Lock, Add Safe Broadcast

**Files:**
- Modify: `lib/forja/processor.ex`
- Modify: `test/forja/processor_test.exs`

- [ ] **Step 1: Update processor tests**

In `test/forja/processor_test.exs`:

1. Replace all `:genstage` path references with `:oban`:

```elixir
# Change:
assert :ok = Processor.process(:processor_test, event.id, :genstage)
# To:
assert :ok = Processor.process(:processor_test, event.id, :oban)
```

(Apply to all 3 occurrences in the test file)

2. Add a test for `mark_processed` failure returning error:

```elixir
test "returns error when mark_processed fails" do
  event = insert_event!("test:success")
  # Delete the event after loading so update fails
  Repo.delete!(event)

  assert {:error, _reason} = Processor.process(:processor_test, event.id, :oban)
end
```

Wait — actually the Processor loads the event from DB first, and if not found returns `:ok`. So this test scenario won't work as described. The `mark_processed` failure case happens when the event exists at load time but the update fails (e.g., concurrent deletion). This is an edge case that's hard to test without mocking the repo. Skip this specific test — the non-bang behavior is verified by the code change itself.

3. Add PubSub setup for `safe_broadcast` testing. In the test `setup` block, start PubSub and update the config:

```elixir
setup do
  Process.register(self(), :processor_test)
  start_supervised!({Phoenix.PubSub, name: Forja.ProcessorTestPubSub})

  config =
    Config.new(
      name: :processor_test,
      repo: Repo,
      pubsub: Forja.ProcessorTestPubSub,
      handlers: [SuccessHandler, ErrorHandler, RaisingHandler]
    )

  Config.store(config)
  # ... registry setup unchanged
end
```

4. Add test for PubSub broadcast after processing:

```elixir
test "broadcasts :forja_event_processed after processing" do
  Phoenix.PubSub.subscribe(Forja.ProcessorTestPubSub, "forja:events")
  event = insert_event!("test:success")

  assert :ok = Processor.process(:processor_test, event.id, :oban)

  assert_receive {:forja_event_processed, %Event{id: id}}
  assert id == event.id
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/processor_test.exs`
Expected: FAIL — broadcast not happening, path references wrong

- [ ] **Step 3: Rewrite Processor**

Replace `lib/forja/processor.ex` with:

```elixir
defmodule Forja.Processor do
  @moduledoc """
  Functional core of event processing.

  Orchestrates the flow:
  1. Loads the event from the database
  2. Checks if it has already been processed (`processed_at`)
  3. Dispatches to handlers via Registry
  4. Marks as processed
  5. Broadcasts via PubSub

  Called by the Oban worker and the reconciliation worker.
  This module has no state — it is a pure functional module.
  """

  require Logger

  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Telemetry

  @spec process(atom(), String.t(), atom()) :: :ok | {:error, term()}
  def process(name, event_id, path) do
    config = Config.get(name)

    case config.repo.get(Event, event_id) do
      nil ->
        Logger.warning("Forja: event #{event_id} not found in database", domain: [:forja])
        :ok

      %Event{processed_at: processed_at} when not is_nil(processed_at) ->
        :ok

      %Event{} = event ->
        dispatch_to_handlers(config, name, event, path)

        case mark_processed(config, event) do
          {:ok, updated_event} ->
            safe_broadcast(config, updated_event, :forja_event_processed)
            :ok

          {:error, changeset} ->
            Logger.error(
              "Forja: failed to mark event #{event_id} as processed: #{inspect(changeset.errors)}",
              domain: [:forja]
            )
            {:error, changeset}
        end
    end
  end

  defp dispatch_to_handlers(_config, name, event, path) do
    handlers = Registry.handlers_for(name, event.type)

    Process.put(:forja_correlation_id, event.correlation_id)
    Process.put(:forja_causation_event_id, event.id)

    Enum.each(handlers, fn handler ->
      start_time = System.monotonic_time()
      meta = %{forja_name: name, path: path, correlation_id: event.correlation_id, causation_id: event.id}

      try do
        case handler.handle_event(event, meta) do
          :ok ->
            duration = System.monotonic_time() - start_time
            Telemetry.emit_processed(name, %{type: event.type, handler: handler, path: path, duration: duration})

          {:error, reason} ->
            Logger.error(
              "Forja: handler #{inspect(handler)} returned error for event #{event.id}: #{inspect(reason)}",
              domain: [:forja]
            )
            Telemetry.emit_failed(name, %{type: event.type, handler: handler, path: path, reason: reason})
            maybe_on_failure(handler, event, {:error, reason}, meta)
        end
      rescue
        exception ->
          Logger.error(
            "Forja: handler #{inspect(handler)} raised for event #{event.id}: #{Exception.message(exception)}",
            domain: [:forja]
          )
          Telemetry.emit_failed(name, %{type: event.type, handler: handler, path: path, reason: exception})
          maybe_on_failure(handler, event, {:raised, exception}, meta)
      end
    end)

    :ok
  after
    Process.delete(:forja_correlation_id)
    Process.delete(:forja_causation_event_id)
  end

  defp mark_processed(config, event) do
    event
    |> Event.mark_processed_changeset()
    |> config.repo.update()
  end

  defp safe_broadcast(config, event, tag) do
    topic = "#{config.event_topic_prefix}:events"
    Phoenix.PubSub.broadcast(config.pubsub, topic, {tag, event})
  rescue
    error ->
      Logger.warning("Forja: PubSub broadcast failed: #{inspect(error)}", domain: [:forja])
      :ok
  end

  defp maybe_on_failure(handler, event, reason, meta) do
    if function_exported?(handler, :on_failure, 3) do
      try do
        handler.on_failure(event, reason, meta)
      rescue
        exception ->
          Logger.error(
            "Forja: on_failure/3 raised in #{inspect(handler)} for event #{event.id}: #{Exception.message(exception)}",
            domain: [:forja]
          )
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/processor_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/forja/processor.ex test/forja/processor_test.exs
git commit -m "refactor: remove advisory lock from Processor, add safe_broadcast post-processing"
```

---

## Task 5: Workers — Update ProcessEventWorker and ReconciliationWorker

**Files:**
- Modify: `lib/forja/workers/process_event_worker.ex`
- Modify: `lib/forja/workers/reconciliation_worker.ex`
- Modify: `test/forja/workers/process_event_worker_test.exs`
- Modify: `test/forja/workers/reconciliation_worker_test.exs`

- [ ] **Step 1: Update ProcessEventWorker tests**

No `:skipped, :locked` tests exist currently — the worker returns `:ok` for that case. Just verify existing tests still pass after changes.

- [ ] **Step 2: Update ProcessEventWorker**

In `lib/forja/workers/process_event_worker.ex`:

1. Change `unique: [keys: [:event_id], period: 300]` to `unique: [keys: [:event_id], period: 900]`
2. Remove `{:skipped, :locked} -> :ok` clause from `perform/1`
3. Update `@moduledoc` — remove dual-path references

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: %{"event_id" => event_id, "forja_name" => forja_name}}) do
  name = String.to_existing_atom(forja_name)

  case Forja.Processor.process(name, event_id, :oban) do
    :ok -> :ok
    {:error, reason} -> {:error, reason}
  end
rescue
  ArgumentError -> {:cancel, "Unknown Forja instance: #{forja_name}"}
end
```

- [ ] **Step 3: Update ReconciliationWorker**

In `lib/forja/workers/reconciliation_worker.ex`:

1. Remove `{:skipped, :locked} -> :ok` clause from `reconcile_event/4`
2. Update `@moduledoc` to remove GenStage references
3. Add `has_active_oban_job?/2` check before processing — skip events that already have an active Oban job to prevent concurrent handler execution (spec requirement from "Concurrent processing note"):

```elixir
defp reconcile_event(config, forja_name, event, max_retries) do
  if has_active_oban_job?(config.repo, event.id) do
    :ok
  else
    case Forja.Processor.process(forja_name, event.id, :reconciliation) do
      :ok ->
        Telemetry.emit_reconciled(forja_name, event.id)

      {:error, _reason} ->
        updated_event =
          event
          |> Event.increment_reconciliation_changeset()
          |> config.repo.update!()

        if updated_event.reconciliation_attempts >= max_retries do
          Telemetry.emit_abandoned(forja_name, event.id, updated_event.reconciliation_attempts)
          DeadLetter.maybe_notify(config.dead_letter, updated_event, :reconciliation_exhausted)
        end
    end
  end
end

defp has_active_oban_job?(repo, event_id) do
  repo.exists?(
    from(j in "oban_jobs",
      where: j.worker == "Forja.Workers.ProcessEventWorker",
      where: fragment("?->>'event_id' = ?", j.args, ^event_id),
      where: j.state in ["available", "executing", "scheduled", "retryable"]
    )
  )
end
```

4. Add test in `test/forja/workers/reconciliation_worker_test.exs`:

```elixir
test "skips events that have an active Oban job" do
  event = insert_event!("reconciliation_test:event")

  # Insert an active Oban job for the event
  %{event_id: event.id, forja_name: "reconciliation_test"}
  |> ProcessEventWorker.new()
  |> Oban.insert!()

  # Reconciliation should skip this event
  reconcile_event(config, :reconciliation_test, event, 3)

  # Event should NOT be processed (no processed_at set)
  reloaded = Repo.get!(Event, event.id)
  assert is_nil(reloaded.processed_at)
end
```

- [ ] **Step 4: Run worker tests**

Run: `cd /Users/lucas/astride/forja && mix test test/forja/workers/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/forja/workers/process_event_worker.ex lib/forja/workers/reconciliation_worker.ex test/forja/workers/
git commit -m "refactor: update workers — remove skipped:locked clause, increase unique period to 900s"
```

---

## Task 6: Main Module — Remove GenStage, Add transaction/2 and broadcast_event/2

This is the largest task. It modifies `lib/forja.ex` to:
- Remove GenStage from supervision tree
- Remove `notify_producers/2`
- Replace `after_emit` with `safe_broadcast`
- Add `transaction/2`
- Add `broadcast_event/2`
- Thread queue from schema into Oban job insertion

**Files:**
- Modify: `lib/forja.ex`
- Modify: `test/forja_test.exs`

- [ ] **Step 1: Write tests for new functions**

In `test/forja_test.exs`, add to the test module setup — subscribe to PubSub to assert broadcasts:

```elixir
setup do
  Process.register(self(), :emit_test)
  start_supervised!({Phoenix.PubSub, name: Forja.EmitTestPubSub})
  start_supervised!({Oban, name: Forja.TestOban, repo: Repo, queues: false, testing: :inline})

  start_supervised!(
    {Forja,
     name: :emit_test,
     repo: Repo,
     pubsub: Forja.EmitTestPubSub,
     oban_name: Forja.TestOban,
     handlers: [EmitTestHandler]}
  )

  Phoenix.PubSub.subscribe(Forja.EmitTestPubSub, "forja:events")
  :ok
end
```

Add new test blocks:

```elixir
describe "emit/3 broadcasts" do
  test "broadcasts :forja_event_emitted after emit" do
    {:ok, event} = Forja.emit(:emit_test, EmitTestCreated, payload: %{order_id: "123"}, source: "test")

    assert_receive {:forja_event_emitted, %Event{id: id, type: "emit_test:created"}}
    assert id == event.id
  end
end

describe "transaction/2" do
  test "executes multi and broadcasts events" do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:setup, fn _repo, _changes -> {:ok, :done} end)
      |> Forja.emit_multi(:emit_test, EmitTestMulti,
        payload: %{ref: "tx-test"},
        source: "multi_test"
      )

    assert {:ok, result} = Forja.transaction(multi, :emit_test)
    assert result[:"forja_event_emit_test:multi"].type == "emit_test:multi"

    assert_receive {:forja_event_emitted, %Event{type: "emit_test:multi"}}
  end

  test "returns error tuple on failure" do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:fail, fn _repo, _changes -> {:error, :boom} end)

    assert {:error, :fail, :boom, %{}} = Forja.transaction(multi, :emit_test)
    refute_receive {:forja_event_emitted, _}
  end
end

describe "broadcast_event/2" do
  test "loads event and broadcasts" do
    {:ok, event} = Forja.emit(:emit_test, EmitTestCreated, payload: %{order_id: "bc"})
    # Drain the automatic broadcast from emit
    assert_receive {:forja_event_emitted, _}

    assert :ok = Forja.broadcast_event(:emit_test, event.id)
    assert_receive {:forja_event_emitted, %Event{id: id}}
    assert id == event.id
  end

  test "returns error for non-existent event" do
    assert {:error, :not_found} = Forja.broadcast_event(:emit_test, Ecto.UUID.generate())
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/lucas/astride/forja && mix test test/forja_test.exs`
Expected: FAIL — new functions don't exist, broadcast not happening

- [ ] **Step 3: Update lib/forja.ex**

Changes to make in `lib/forja.ex`:

1. **Remove imports/aliases** for `EventConsumer`, `EventProducer`. Keep `ObanListener`.

2. **Update `init/1`** — remove EventProducer and EventConsumer from children:

```elixir
@impl Supervisor
def init(%Config{} = config) do
  Config.store(config)
  {table, catch_all} = Registry.build(config.handlers)
  Registry.store(config.name, table, catch_all)

  children = [
    {ObanListener, name: config.name}
  ]

  Supervisor.init(children, strategy: :one_for_one)
end
```

3. **Replace `after_emit/3`** with `safe_broadcast`:

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

4. **Remove `notify_producers/2`** entirely.

5. **Update `do_emit/3`** to read queue from schema and pass to Oban job:

In `do_emit/3`, the `attrs` map needs to carry the queue. The schema module is available in `emit/3` before calling `do_emit`. Thread it through:

Change `emit/3` to pass `schema_module` to `do_emit`:

```elixir
# In the resolve_event_type success path, capture schema_module:
case resolve_event_type(type, opts) do
  {:ok, resolved_type, payload, schema_version, schema_module} ->
    # ... build attrs ...
    do_emit(config, name, attrs, schema_module)
```

Update `resolve_event_type` to return the schema module:

```elixir
defp resolve_event_type(schema_module, opts) when is_atom(schema_module) do
  # ... existing validation ...
  case schema_module.parse_payload(raw_payload) do
    {:ok, validated} ->
      string_keyed = stringify_keys(validated)
      {:ok, schema_module.event_type(), string_keyed, schema_module.schema_version(), schema_module}
    {:error, errors} ->
      {:error, Forja.ValidationError.new(schema_module, errors)}
  end
end
```

Update `do_emit/4` to use the queue:

```elixir
defp do_emit(config, name, attrs, schema_module) do
  queue = resolve_queue(config, schema_module)

  multi =
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:event, fn _changes ->
      Event.changeset(%Event{}, attrs)
    end)
    |> Ecto.Multi.run(:oban_job, fn _repo, %{event: event} ->
      job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
      changeset = ProcessEventWorker.new(job_args, queue: :"forja_#{queue}")
      Oban.insert(config.oban_name, changeset)
    end)

  case config.repo.transaction(multi) do
    {:ok, %{event: event}} ->
      after_emit(config, name, event)
      Telemetry.emit_emitted(name, %{type: attrs.type, source: attrs.source, payload: attrs.payload, correlation_id: attrs.correlation_id})
      {:ok, event}

    {:error, :event, changeset, _changes} ->
      {:error, changeset}

    {:error, :oban_job, reason, _changes} ->
      {:error, reason}
  end
end

defp resolve_queue(config, schema_module) do
  if function_exported?(schema_module, :queue, 0) and schema_module.queue() != nil do
    schema_module.queue()
  else
    config.default_queue
  end
end
```

6. **Update `emit_multi/4`** — thread queue into Oban job and fix `resolve_event_type` 5-tuple.

Since `resolve_event_type` now returns a 5-tuple (with `schema_module` as 5th element), update the pattern match inside `emit_multi/4`'s event step. The schema module is the same as the `type` argument so it can be ignored:

```elixir
# In the emit_multi event_key Multi.run step, update the pattern match:
case resolve_event_type(type, opts_for_resolve) do
  {:ok, resolved_type, validated_payload, schema_version, _schema_module} ->
    # ... rest unchanged
```

Update the Oban job insertion Multi step to bind `config` and use `resolve_queue`:

```elixir
|> Ecto.Multi.run(oban_key, fn _repo, changes ->
  case Map.fetch!(changes, event_key) do
    :already_processed -> {:ok, :skipped}
    {:retrying, _event_id} -> {:ok, :skipped}
    {:error, %Forja.ValidationError{}} -> {:error, :validation_failed}
    %Event{} = event ->
      config = Config.get(name)
      queue = resolve_queue(config, type)
      job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
      changeset = ProcessEventWorker.new(job_args, queue: :"forja_#{queue}")
      Oban.insert(config.oban_name, changeset)
  end
end)
```

Note: `type` here is the schema module atom (not the string). `resolve_queue` works with it. `config` is explicitly bound inside the closure.

7. **Add `transaction/2`**:

```elixir
@doc """
Executes an `Ecto.Multi` built with `emit_multi/4` and broadcasts all
emitted events via PubSub after a successful commit.

This is the recommended way to commit transactional event emissions.
Using `Repo.transaction/1` directly is still valid — events will be
processed by Oban regardless; only the PubSub notification is lost.

## Example

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:order, order_changeset)
    |> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
        payload_fn: fn %{order: order} -> %{order_id: order.id} end,
        source: "orders"
      )
    |> Forja.transaction(:my_app)
"""
@spec transaction(Ecto.Multi.t(), atom()) :: {:ok, map()} | {:error, atom(), term(), map()}
def transaction(multi, name) do
  config = Config.get(name)

  case config.repo.transaction(multi) do
    {:ok, results} ->
      results
      |> Enum.each(fn
        {key, %Event{} = event} when is_atom(key) ->
          if key |> Atom.to_string() |> String.starts_with?("forja_event_") do
            safe_broadcast(config, event, :forja_event_emitted)
          end
        _ -> :ok
      end)

      {:ok, results}

    error ->
      error
  end
end
```

8. **Add `broadcast_event/2`**:

```elixir
@doc """
Manually broadcasts a PubSub notification for an event.

Loads the event from the database and broadcasts
`{:forja_event_emitted, %Forja.Event{}}`. Useful for manual control
after `Repo.transaction/1` when not using `Forja.transaction/2`.

Returns `{:error, :not_found}` if the event does not exist.
"""
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

9. **Update `@moduledoc`** — remove dual-path description, update usage examples to show `transaction/2`. Specifically:
   - Replace `"Event Bus with dual-path processing for Elixir."` with `"Event Bus with Oban-backed processing for Elixir."`
   - Remove `"Forja combines PubSub/GenStage latency with Oban delivery guarantees."` sentence
   - Remove `"three-layer deduplication"` reference — replace with `"Oban unique constraint + processed_at safety net"`
   - Update the usage example to remove `consumer_pool_size` if present
   - Add `transaction/2` usage example

10. **Update `emit_multi/4` `@doc`** — the current doc (lines 269-295) extensively references "GenStage fast-path", `notify_producers/2`, and "dual-path design". Replace with:
   - Remove the entire "## GenStage fast-path and emit_multi" section
   - Replace the post-transaction example that calls `notify_producers` with `Forja.transaction/2` usage:

```elixir
@doc """
Adds event emission steps to an existing `Ecto.Multi`.

...

## Post-commit broadcast

Use `Forja.transaction/2` to execute the Multi and automatically
broadcast all emitted events via PubSub:

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:order, order_changeset)
    |> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
        payload_fn: fn %{order: order} -> %{order_id: order.id} end,
        source: "orders"
      )
    |> Forja.transaction(:my_app)

Using `Repo.transaction/1` directly is still valid — events will be
processed by Oban regardless; only the PubSub notification is lost.
"""
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/lucas/astride/forja && mix test test/forja_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/forja.ex test/forja_test.exs
git commit -m "feat: remove GenStage, add transaction/2 and broadcast_event/2, queue routing"
```

---

## Task 7: Delete Removed Modules

**Files:**
- Delete: `lib/forja/event_producer.ex`
- Delete: `lib/forja/event_consumer.ex`
- Delete: `lib/forja/event_worker.ex`
- Delete: `lib/forja/advisory_lock.ex`
- Delete: `test/forja/event_producer_test.exs`
- Delete: `test/forja/event_consumer_test.exs`
- Delete: `test/forja/advisory_lock_test.exs`

- [ ] **Step 1: Delete files**

```bash
cd /Users/lucas/astride/forja
rm lib/forja/event_producer.ex
rm lib/forja/event_consumer.ex
rm lib/forja/event_worker.ex
rm lib/forja/advisory_lock.ex
rm test/forja/event_producer_test.exs
rm test/forja/event_consumer_test.exs
rm test/forja/advisory_lock_test.exs
```

- [ ] **Step 2: Run full test suite**

Run: `cd /Users/lucas/astride/forja && mix test`
Expected: PASS — no remaining references to deleted modules

- [ ] **Step 3: Fix any remaining references**

If any test or module still references `EventProducer`, `EventConsumer`, `EventWorker`, or `AdvisoryLock`, update those references. Common places to check:
- `lib/forja.ex` aliases (should already be removed in Task 6)
- `test/forja/correlation_propagation_test.exs` — may reference `:genstage` path
- `test/forja/correlation_test.exs` — may reference `:genstage` path

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: delete GenStage and AdvisoryLock modules"
```

---

## Task 8: Update Docs, Handler, Testing Module, and mix.exs

**Files:**
- Modify: `lib/forja/handler.ex`
- Modify: `lib/forja/testing.ex`
- Modify: `mix.exs`

- [ ] **Step 1: Update handler.ex moduledoc**

In `lib/forja/handler.ex`:

Change `"Behaviour module for event handlers in Forja."` moduledoc — replace any reference to "dual-path pipeline" with "Oban processing pipeline". Update the `meta` doc to remove `:genstage` from the `:path` values list.

At line 65: change ``:genstage`, `:oban`, `:reconciliation`, `:inline`` to ``:oban`, `:reconciliation`, `:inline``.

- [ ] **Step 2: Update testing.ex moduledoc**

In `lib/forja/testing.ex`:

Change `"without GenStage or Oban"` to `"synchronously without Oban"` in the inline mode comment.

- [ ] **Step 3: Update mix.exs**

1. Change `@version "0.2.2"` to `@version "0.3.0"`
2. Update `description` — change `"Event Bus with dual-path processing"` to `"Event Bus with Oban-backed processing for Elixir."`
3. Remove `{:gen_stage, "~> 1.2"}` from `deps` if present. Check if it exists first:

Run: `grep gen_stage /Users/lucas/astride/forja/mix.exs`

4. In `groups_for_modules/0`, remove the `"GenStage Pipeline"` group entirely (it references deleted modules `Forja.EventProducer`, `Forja.EventConsumer`, `Forja.EventWorker`). Also remove `Forja.AdvisoryLock` from the `Infrastructure` group.

- [ ] **Step 4: Run full test suite**

Run: `cd /Users/lucas/astride/forja && mix test`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add lib/forja/handler.ex lib/forja/testing.ex mix.exs
git commit -m "chore: bump to v0.3.0, update docs for Oban-only architecture"
```

---

## Task 9: Final Verification — Full Test Suite and Compilation

- [ ] **Step 1: Clean compile**

Run: `cd /Users/lucas/astride/forja && mix clean && mix compile --warnings-as-errors`
Expected: 0 warnings, 0 errors

- [ ] **Step 2: Full test suite**

Run: `cd /Users/lucas/astride/forja && mix test`
Expected: ALL PASS, 0 failures

- [ ] **Step 3: Check for stale references**

Run grep for removed module names:

```bash
cd /Users/lucas/astride/forja
grep -r "EventProducer\|EventConsumer\|EventWorker\|AdvisoryLock\|advisory_lock\|notify_producers\|consumer_pool_size\|:genstage" lib/ test/ --include="*.ex" --include="*.exs"
```

Expected: No matches (or only in docs/specs which are acceptable).

- [ ] **Step 4: Verify no gen_stage dependency**

Run: `cd /Users/lucas/astride/forja && grep gen_stage mix.exs mix.lock`
Expected: No matches (or only in lock file if not yet cleaned).

- [ ] **Step 5: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "chore: final cleanup for v0.3.0 release"
```
