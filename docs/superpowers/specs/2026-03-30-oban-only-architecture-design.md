# Forja v0.3.0 — Oban-Only Architecture

**Date:** 2026-03-30
**Status:** Approved
**Breaking:** Yes (v0.2.x → v0.3.0)

## Motivation

Forja v0.2.x uses a dual-path architecture: events are processed by both GenStage (millisecond latency via PubSub) and Oban (guaranteed delivery via persistent jobs). Three layers of deduplication (PostgreSQL advisory lock + `processed_at` column + Oban unique constraint) ensure exactly-once processing.

This dual-path introduces significant complexity — advisory locks, three GenStage modules (`EventProducer`, `EventConsumer`, `EventWorker`), race condition handling, and deduplication logic in the Processor — for a benefit (millisecond latency) that most use cases don't require. The emitter calls `emit/3` and moves on; whether the handler runs in 3ms or 3s is irrelevant to the emitter.

This redesign removes GenStage as a processing path, making Oban the sole event processor. PubSub shifts from a processing trigger to a notification channel for post-emit and post-processing broadcasts.

## Architecture Overview

```
emit/3 ──> [DB: event + Oban job] ──> PubSub broadcast (emitted)
            (atomic transaction)

emit_multi/4 ──> [Multi steps]
                  |
transaction/2 ──> Repo.transaction + PubSub broadcast (emitted, auto)

Oban (sole processing path):
  ProcessEventWorker
    -> Processor.process(name, event_id, :oban)
      -> load event
      -> check processed_at
      -> dispatch handlers (Registry)
        -> handler may call emit/3 (chains new events)
      -> mark processed_at
      -> PubSub broadcast (processed)

Reconciliation (cron) -- catches orphaned events
ObanListener -- detects discarded jobs -> DeadLetter

Supervision tree:
  Forja.Supervisor
    └── ObanListener
```

## Event Flow

### Direct emission (`Forja.emit/3`)

1. Validate payload against event schema
2. `BEGIN TRANSACTION`
   - `INSERT` into `forja_events` table
   - `INSERT` Oban `ProcessEventWorker` job (queue read from schema, prefixed with `forja_`)
3. `COMMIT`
4. PubSub broadcast `{:forja_event_emitted, %Forja.Event{}}`
5. Telemetry `[:forja, :event, :emitted]`

No change to the public API signature.

### Transactional emission (`Forja.emit_multi/4` + `Forja.transaction/2`)

`emit_multi/4` continues to insert both the event and the Oban job as Multi steps (no change from v0.2.x). `Forja.transaction/2` is a convenience wrapper that executes the Multi and adds PubSub broadcast post-commit.

1. User builds `Ecto.Multi` pipeline with domain operations and `Forja.emit_multi/4` steps
2. User calls `Forja.transaction(multi, name)` instead of `Repo.transaction(multi)`
3. `Forja.transaction/2` internally:
   - Calls `config.repo.transaction(multi)`
   - On success: scans results for keys matching `:forja_event_*` prefix, broadcasts each `%Forja.Event{}` via PubSub as `{:forja_event_emitted, event}`
   - On error: returns the Ecto.Multi 4-tuple error as-is

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:order, order_changeset)
|> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
    payload_fn: fn %{order: order} -> %{order_id: order.id} end,
    source: "orders"
  )
|> Forja.transaction(:my_app)
```

Using `Repo.transaction/1` directly (instead of `Forja.transaction/2`) is still valid — events will be processed by Oban regardless; the only thing lost is the `:forja_event_emitted` PubSub notification.

For users who need manual control, `Forja.broadcast_event(name, event_id)` is available as a standalone function. It loads the event from the database and broadcasts `{:forja_event_emitted, %Forja.Event{}}`. Returns `{:error, :not_found}` if the event does not exist.

### Processing (Oban — sole path)

1. Oban dequeues `ProcessEventWorker` job
2. `Processor.process(name, event_id, :oban)`:
   - Load event from database
   - Check `processed_at` — if set, return `:ok` (already processed)
   - Dispatch to handlers via `Registry.handlers_for(name, event.type)`
   - For each handler:
     - Call `handler.handle_event(event, meta)`
     - On error or exception: call `handler.on_failure/3` if implemented
     - Emit telemetry per handler
   - Mark `processed_at = DateTime.utc_now()`
   - PubSub broadcast `{:forja_event_processed, %Forja.Event{}}`
3. Return `:ok`

### Event chaining

Handlers chain events by calling `Forja.emit/3` inside `handle_event/2`. This creates a new event + Oban job atomically. Correlation and causation IDs propagate automatically via the Process dictionary (unchanged from v0.2.x).

```
Oban processes "payment:confirmed"
  -> InvoiceHandler calls Forja.emit(:my_app, InvoiceGenerated, ...)
    -> new event + Oban job (atomic)
      -> Oban processes "invoice:generated"
        -> EmailHandler calls Forja.emit(:my_app, EmailSent, ...)
          -> ...
```

**Chained emission failures:** If `Forja.emit/3` fails inside a handler (e.g., database error), the handler should return `{:error, reason}` to trigger `on_failure/3`, where retry or compensation logic can be implemented. The parent event is still marked as processed — handlers are responsible for their own failure recovery.

### Handler failure semantics

Handler failures do **not** prevent the event from being marked as processed. After all handlers are dispatched (regardless of individual success or failure), `processed_at` is set. This means:

- Handler errors invoke `on_failure/3` (if implemented) and emit `[:forja, :event, :failed]` telemetry
- Handler errors do **not** cause Oban-level retries
- Handlers must be idempotent and are responsible for their own retry logic via `on_failure/3`

This is unchanged from v0.2.x but worth restating: with advisory locks removed, implementers should not expect Oban retries to compensate for handler failures.

## Processor Simplification

The Processor drops all dual-path concerns:

**Removed:**
- Advisory lock acquisition (`pg_try_advisory_xact_lock`)
- Lock contention handling (`{:skipped, :locked}`)
- `:genstage` path

**Kept:**
- `processed_at` check (safety net against duplicate processing)
- Handler dispatch via Registry
- `on_failure/3` callback
- Telemetry emission
- Correlation/causation ID propagation via Process dictionary

**Return type changes:**

```elixir
# Before
@spec process(atom(), String.t(), atom()) :: :ok | {:skipped, :locked} | {:error, term()}
# After
@spec process(atom(), String.t(), atom()) :: :ok | {:error, term()}
```

`{:skipped, :locked}` is removed from the return type. The `ReconciliationWorker.reconcile_event/4` and `ProcessEventWorker.perform/1` should have their `{:skipped, :locked}` clauses removed as dead code.

**`path` parameter values:** `:oban`, `:reconciliation`, `:inline` (`:genstage` removed)

## PubSub — Notification Only

PubSub shifts from a processing trigger to a notification channel.

**Topic:** `"#{event_topic_prefix}:events"` (default: `"forja:events"`)

**Messages:**

| Message | When | Use case |
|---|---|---|
| `{:forja_event_emitted, %Forja.Event{}}` | After emit, before processing | UI "pending" states, audit logging |
| `{:forja_event_processed, %Forja.Event{}}` | After all handlers ran | LiveView updates, cache invalidation |

Both messages carry the full `%Forja.Event{}` struct (not just the event ID).

**Subscriber example:**

```elixir
def mount(_params, _session, socket) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "forja:events")
  {:ok, socket}
end

def handle_info({:forja_event_processed, %Forja.Event{type: "payment:confirmed"} = event}, socket) do
  {:noreply, assign(socket, :payment_status, :confirmed)}
end
```

PubSub remains a required dependency. Broadcasts are best-effort — a crashed subscriber loses the notification, but no event data is lost (it's in the database).

## Queue Routing

Event schemas gain an optional `queue` macro. Forja prefixes the queue name with `forja_` internally to avoid collisions with user-defined Oban queues.

```elixir
defmodule MyApp.Events.PaymentConfirmed do
  use Forja.Event.Schema

  event_type "payment:confirmed"
  schema_version 1
  queue :payments  # Oban job goes to :forja_payments

  payload do
    field :order_id, Zoi.string()
    field :amount_cents, Zoi.integer() |> Zoi.positive()
  end
end
```

The `queue` macro is optional. When omitted, the event uses `:default_queue` from the Forja config (default: `:events`, resolves to `:forja_events`).

The schema module exposes `queue/0` returning the configured atom (e.g., `:payments`). At job insertion time, `emit/3` and `emit_multi/4` call `schema_module.queue/0`, prefix with `forja_`, and pass `queue: :forja_payments` to `ProcessEventWorker.new/2`. The `ProcessEventWorker` module default (`queue: :forja_events`) is overridden per-job via this option.

The user configures Oban queues as usual:

```elixir
config :my_app, Oban,
  queues: [forja_events: 5, forja_payments: 10, forja_billing: 3]
```

## Supervision Tree

**Before (v0.2.x):**

```
Forja.Supervisor
├── ObanListener
├── EventProducer (GenStage)
└── EventConsumer (GenStage ConsumerSupervisor)
```

**After (v0.3.0):**

```
Forja.Supervisor
└── ObanListener
```

Concurrency is controlled entirely by Oban queue configuration, not by Forja's `consumer_pool_size`.

## Reconciliation and Dead Letter

Functionally unchanged. Both mechanisms operate exclusively on the Oban path and are unaffected by the GenStage removal.

- **ReconciliationWorker:** Cron job scanning for `processed_at IS NULL` events older than threshold. Attempts processing via `Processor.process(name, event_id, :reconciliation)`.
- **ObanListener:** Telemetry handler detecting discarded `ProcessEventWorker` jobs. Triggers `DeadLetter.maybe_notify/3`.
- **DeadLetter behaviour:** Unchanged.

**Concurrent processing note:** Without advisory locks, if reconciliation runs while an Oban retry is in progress for the same event, both could dispatch handlers concurrently. The `processed_at` check prevents full duplication but does not prevent overlapping handler execution. This is acceptable because handlers must be idempotent per the existing contract (`Forja.Handler` documentation). To further mitigate, the reconciliation worker should skip events that have an active (non-discarded) Oban job in the queue.

## Public API Changes

### New functions

| Function | Signature | Description |
|---|---|---|
| `Forja.transaction/2` | `transaction(Ecto.Multi.t(), atom()) :: {:ok, map()} \| {:error, atom(), term(), map()}` | Executes Multi via Repo, broadcasts all Forja events post-commit |
| `Forja.broadcast_event/2` | `broadcast_event(atom(), String.t()) :: :ok \| {:error, :not_found}` | Loads event from DB, broadcasts `{:forja_event_emitted, %Event{}}` via PubSub |

### Removed functions

| Function | Replacement |
|---|---|
| `Forja.notify_producers/2` | `Forja.broadcast_event/2` or `Forja.transaction/2` |

### Config changes

| Option | Change |
|---|---|
| `:consumer_pool_size` | **Removed** — concurrency via Oban queue config |
| `:default_queue` | **New** — default queue name for schemas without `:queue` (default: `:events`) |

### Handler behaviour

No changes. `event_types/0`, `handle_event/2`, `on_failure/3` remain identical.

### Event Schema

| Option | Change |
|---|---|
| `queue` macro | **New** — optional macro in schema DSL, sets Oban queue name without `forja_` prefix (default: uses `:default_queue` from config). Generates `queue/0` function. |

## Modules Removed

| Module | Reason |
|---|---|
| `Forja.EventProducer` | GenStage producer — no longer needed |
| `Forja.EventConsumer` | GenStage consumer supervisor — no longer needed |
| `Forja.EventWorker` | Task wrapper for GenStage — no longer needed |
| `Forja.AdvisoryLock` | PostgreSQL advisory locks — no longer needed without dual-path |

## Deduplication

**Before:** 3 layers (advisory lock + `processed_at` + Oban unique)
**After:** 2 layers (Oban unique constraint + `processed_at` as safety net)

The Oban unique constraint (`[keys: [:event_id], period: 900]`) prevents duplicate jobs. The period is increased from 300 to 900 seconds (15 minutes) to match the reconciliation threshold, preventing the reconciliation worker from inserting duplicate jobs when the Oban queue has a backlog. The `processed_at` column check inside the Processor is a safety net for edge cases.

## Telemetry Changes

**Removed events:**
- `[:forja, :event, :skipped]` — was emitted when advisory lock was held by another path. No longer applicable.
- `[:forja, :producer, :buffer_size]` — was emitted by `EventProducer` (GenStage). No longer applicable.

**Modified metadata:**
- `[:forja, :event, :processed]` — the `:path` metadata no longer includes `:genstage` as a value
- `[:forja, :event, :failed]` — same `:path` change

**Unchanged events:**
- `[:forja, :event, :emitted]`, `[:forja, :event, :dead_letter]`, `[:forja, :event, :abandoned]`, `[:forja, :event, :reconciled]`, `[:forja, :event, :deduplicated]`, `[:forja, :event, :validation_failed]`

## Migration

No database migrations required. The `forja_events` table schema is unchanged. The `processed_at` and `reconciliation_attempts` columns continue to serve the same purpose.

The `advisory_lock` function is no longer called but does not need to be dropped from PostgreSQL — it's a built-in function, not a custom one.

## Version

**v0.3.0** — breaking change due to:
- Removal of `Forja.notify_producers/2`
- Removal of `:consumer_pool_size` config option
- Removal of `[:forja, :event, :skipped]` telemetry event
- New PubSub message format (`{:forja_event_emitted, %Event{}}` and `{:forja_event_processed, %Event{}}` instead of `{:forja_event, event_id}`)
- Oban unique period changed from 300 to 900 seconds
