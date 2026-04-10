# Architecture

Forja uses Oban as the sole processing engine. Events are persisted and enqueued atomically, with PubSub broadcasts for real-time notifications. This guide explains the internal architecture.

## Event lifecycle

When you call `Forja.emit/3`, two things happen inside a single database transaction:

1. The event is inserted into the `forja_events` table
2. An Oban job (`ProcessEventWorker`) is enqueued

After the transaction commits:

3. A PubSub broadcast sends `{:forja_event_emitted, %Event{}}` (best-effort, `try/rescue` protected)

```
                    +-------------------+
                    |   Forja.emit/3    |
                    +--------+----------+
                             |
                    INSERT event + Oban job
                    (single Ecto.Multi transaction)
                             |
              +--------------+--------------+
              |                             |
      PubSub broadcast              Oban polls
      (best-effort notify)                 |
              |                    +-------v--------+
              v                    | ProcessEvent   |
    {:forja_event_emitted,         | Worker         |
     %Event{}}                     +-------+--------+
                                           |
                                   +-------v--------+
                                   |  Processor     |
                                   | (shared core)  |
                                   +-------+--------+
                                           |
                                           v
                                   {:forja_event_processed,
                                    %Event{}}
```

PubSub is notification-only. It is not a processing trigger and never affects delivery guarantees.

## Idempotent processing

Two layers prevent duplicate processing:

### 1. Oban unique constraint

`ProcessEventWorker` uses `unique: [keys: [:event_id], period: 900]` to prevent duplicate jobs for the same event within a 15-minute window.

### 2. `processed_at` safety net

The Processor loads the event and checks `processed_at` before dispatching handlers. If the event was already processed, it returns early. After all handlers run, the Processor marks the event via a non-bang `Repo.update/1`.

## Supervision tree

```
Forja.Supervisor (strategy: :one_for_one)
  +-- Forja.ObanListener
```

### ObanListener

A GenServer that attaches a telemetry handler to `[:oban, :job, :stop]`. When a `ProcessEventWorker` job is discarded by Oban (all retry attempts exhausted), it triggers the dead letter flow.

The telemetry callback resolves the listener by its **registered name** (not PID) to survive process restarts.

## Oban workers

Two Oban workers run outside the supervision tree (managed by Oban's own supervisor):

### ProcessEventWorker

- Queue: `:forja_events` (default), or per-event via the `queue` macro in `Event.Schema`
- Max attempts: 3
- Unique: by `event_id`, 900-second period
- Calls `Forja.Processor.process/3` with the `:oban` path

### ReconciliationWorker

- Queue: `:forja_reconciliation`
- Max attempts: 1 (cron job, retries handled internally)
- Runs periodically via Oban crontab
- Skips events that have active Oban jobs before attempting processing

Scans for events where `processed_at IS NULL` and `inserted_at` exceeds the threshold. For each stale event, attempts processing via the Processor. Tracks `reconciliation_attempts` and triggers dead letter handling when the limit is reached.

## Per-event queue routing

Event schema modules can declare a custom Oban queue using the `:queue` option. Forja prefixes the name with `forja_` internally:

```elixir
defmodule MyApp.Events.PaymentReceived do
  use Forja.Event.Schema,
    event_type: "payment:received",
    queue: :payments  # routes to :forja_payments

  payload do
    field :amount_cents, Zoi.integer() |> Zoi.positive()
  end
end
```

Events without a `queue` declaration use the instance's `:default_queue` (defaults to `:events`, i.e. `:forja_events`).

## Transactional emission

`Forja.transaction/2` wraps an `Ecto.Multi` that contains `emit_multi` steps. After a successful commit, it automatically broadcasts `{:forja_event_emitted, %Event{}}` for each emitted event:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:order, order_changeset)
|> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
  payload_fn: fn %{order: order} -> %{order_id: order.id} end,
  source: "orders"
)
|> Forja.transaction(:my_app)
```

`Forja.broadcast_event/2` allows manually broadcasting a previously emitted event by its ID.

## Dead letter handling

An event becomes a "dead letter" when all processing attempts are exhausted. This can happen through two paths:

1. **Oban discards the job** -- The `ObanListener` detects this via telemetry and emits `[:forja, :event, :dead_letter]`
2. **Reconciliation exhausts retries** -- The `ReconciliationWorker` emits `[:forja, :event, :abandoned]`

In both cases, if a `Forja.DeadLetter` module is configured, its `handle_dead_letter/2` callback is invoked.

## Versioned migrations

Forja uses an Oban-style versioned migration system. Instead of individual migration files for each schema change, all DDL is consolidated into numbered version modules (`V01`, `V02`, etc.) under `Forja.Migrations.Postgres`.

### How it works

1. **Version tracking** -- The current schema version is stored as a PostgreSQL table comment on `forja_events` (zero overhead, no extra tables)
2. **Delta execution** -- `Forja.Migration.up/1` reads the current version from the comment, then applies only the missing versions up to the target
3. **Startup verification** -- `Forja.init/1` compares the database version against the library's `current_version/0`. If behind, it raises with a copy-pasteable migration snippet

### Adding a new version (maintainer guide)

1. Create `lib/forja/migrations/postgres/v02.ex` with `up/1` and `down/1`
2. Bump `@current_version` in `Forja.Migrations.Postgres`
3. Add tests and update the version matrix in `Forja.Migration` moduledoc

## Handler dispatch

The `Processor` dispatches events to all matching handlers via the `Registry`. Handlers are matched by event type, and catch-all handlers (returning `:all` from `event_types/0`) receive every event.

Key behavior: **all handlers run regardless of individual failures**. If a handler returns `{:error, reason}` or raises an exception, the error is logged and telemetry is emitted, but remaining handlers still execute. The event is marked as processed after all handlers have been called.

This design means handlers should be **idempotent** and should enqueue their own retry mechanism for operations that may fail (e.g., sending an email via a separate Oban job). Handlers that define `on_failure/3` receive a callback on error or exception.
