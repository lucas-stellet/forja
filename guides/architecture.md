# Architecture

Forja's dual-path design ensures events are processed quickly **and** reliably. This guide explains the internal architecture.

## Dual-path processing

When you call `Forja.emit/3`, two things happen inside a single database transaction:

1. The event is inserted into the `forja_events` table
2. An Oban job (`ProcessEventWorker`) is created

After the transaction commits:

3. A PubSub broadcast notifies the GenStage producer
4. The GenStage consumer picks up the event and processes it immediately

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
              |                             |
      +-------v--------+           +-------v--------+
      | GenStage        |           | ProcessEvent   |
      | EventProducer   |           | Worker         |
      | -> Consumer     |           |                |
      +-------+--------+           +-------+--------+
              |                             |
              +-------------+---------------+
                            |
               advisory lock (exactly-once)
                            |
                    +-------v--------+
                    |  Processor     |
                    | (shared core)  |
                    +----------------+
```

## Exactly-once processing

Three layers prevent duplicate processing:

### 1. PostgreSQL advisory lock

`pg_try_advisory_xact_lock` is acquired at the start of processing. If another path already holds the lock for this event, processing is skipped immediately. The lock is transaction-scoped and released automatically on commit/rollback.

### 2. `processed_at` column check

Inside the advisory lock, the Processor checks if `processed_at` is already set. If the event was already processed (by the other path), it returns early.

### 3. Oban unique jobs

The `ProcessEventWorker` uses Oban's `unique: [keys: [:event_id], period: 300]` to prevent duplicate jobs for the same event within a 5-minute window.

## Supervision tree

```
Forja.Supervisor (strategy: :one_for_one)
  +-- Forja.ObanListener
  +-- Forja.EventProducer (GenStage producer)
  +-- Forja.EventConsumer (ConsumerSupervisor)
        +-- Task (transient, one per event)
```

### ObanListener

A GenServer that attaches a telemetry handler to `[:oban, :job, :stop]`. When a `ProcessEventWorker` job is discarded by Oban (all retry attempts exhausted), it triggers the dead letter flow.

The telemetry callback resolves the listener by its **registered name** (not PID) to survive process restarts.

### EventProducer

A GenStage producer that subscribes to the PubSub topic `"{prefix}:events"`. When a `{:forja_event, event_id}` message arrives, the event ID is emitted to consumers via GenStage's native buffer.

The buffer defaults to 10,000 events. When full, GenStage drops the oldest events -- this is safe because the Oban path guarantees delivery.

### EventConsumer

A `ConsumerSupervisor` that spawns one transient `Task` per event. Each task calls `Forja.Processor.process/3` with the `:genstage` path. The `max_demand` option controls concurrency (default: 4).

## Oban workers

Two Oban workers run outside the supervision tree (managed by Oban's own supervisor):

### ProcessEventWorker

- Queue: `:forja_events`
- Max attempts: 3
- Unique: by `event_id`, 300-second period
- Calls `Forja.Processor.process/3` with the `:oban` path

### ReconciliationWorker

- Queue: `:forja_reconciliation`
- Max attempts: 1 (cron job, retries handled internally)
- Runs periodically via Oban crontab

Scans for events where `processed_at IS NULL` and `inserted_at` exceeds the threshold. For each stale event, attempts processing via the Processor. Tracks `reconciliation_attempts` and triggers dead letter handling when the limit is reached.

## Dead letter handling

An event becomes a "dead letter" when all processing attempts are exhausted. This can happen through two paths:

1. **Oban discards the job** -- The `ObanListener` detects this via telemetry and emits `[:forja, :event, :dead_letter]`
2. **Reconciliation exhausts retries** -- The `ReconciliationWorker` emits `[:forja, :event, :abandoned]`

In both cases, if a `Forja.DeadLetter` module is configured, its `handle_dead_letter/2` callback is invoked.

## Handler dispatch

The `Processor` dispatches events to all matching handlers via the `Registry`. Handlers are matched by event type, and catch-all handlers (returning `:all` from `event_types/0`) receive every event.

Key behavior: **all handlers run regardless of individual failures**. If a handler returns `{:error, reason}` or raises an exception, the error is logged and telemetry is emitted, but remaining handlers still execute. The event is marked as processed after all handlers have been called.

This design means handlers should be **idempotent** and should enqueue their own retry mechanism for operations that may fail (e.g., sending an email via a separate Oban job).
