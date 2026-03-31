# Error Handling in Handlers

Forja handlers are **thin orchestrators** — they react to events and delegate work. When that work can fail (external APIs, email delivery, third-party integrations), the handler needs a strategy for dealing with failures.

## How Forja processes handlers

When an event is dispatched, the Processor calls every matching handler. Key behavior:

1. **All handlers run regardless of individual failures.** If Handler A fails, Handlers B and C still execute.
2. **The event is marked as processed after all handlers run.** Even if some returned `{:error, reason}`.
3. **Failed handlers are not automatically retried.** The error is logged and `[:forja, :event, :failed]` telemetry is emitted, but the handler will not be called again for this event.

This is intentional. The Processor's job is exactly-once *dispatch*, not exactly-once *success*. Retry semantics belong to the handler, because only the handler knows whether a failure is transient or permanent.

## The pattern: delegate to Oban

The recommended approach for operations that can fail is to **enqueue a dedicated Oban worker** from inside the handler. The handler becomes a router that translates domain events into background jobs:

```elixir
defmodule MyApp.Events.OrderNotifier do
  @behaviour Forja.Handler

  @impl true
  def event_types, do: ["order:created"]

  @impl true
  def handle_event(%Forja.Event{payload: payload}, _meta) do
    # Enqueue a dedicated worker that handles its own retries
    %{order_id: payload["order_id"], email: payload["email"]}
    |> MyApp.Workers.SendConfirmationEmail.new(max_attempts: 5)
    |> Oban.insert()

    :ok
  end
end
```

```elixir
defmodule MyApp.Workers.SendConfirmationEmail do
  use Oban.Worker, queue: :notifications, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id, "email" => email}}) do
    case MyApp.Mailer.send_confirmation(order_id, email) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}  # Oban retries
      {:error, :invalid_email} -> {:discard, "invalid email"}  # permanent, stop
    end
  end
end
```

This gives you:

- **Retry with backoff** — Oban handles exponential backoff automatically
- **Max attempts** — configurable per worker, not per event type
- **Transient vs permanent errors** — return `{:error, reason}` for retry, `{:discard, reason}` to stop
- **Independent failure isolation** — the email worker failing doesn't affect the order status worker
- **Observability** — each worker has its own Oban job with state, attempt count, and error history

## When to use this pattern

Use dedicated workers when the operation:

- **Calls an external service** — HTTP APIs, email providers, payment gateways
- **Can fail transiently** — network timeouts, rate limits, temporary outages
- **Has its own SLA** — email must be sent within 5 minutes, webhook within 30 seconds
- **Needs independent retry config** — 3 attempts for webhooks, 10 for emails

## When NOT to use this pattern

Keep the logic directly in the handler when:

- **The operation is local and fast** — updating a database column, writing to a cache
- **Failure is permanent by nature** — validation logic, business rule checks
- **The operation is idempotent and cheap** — logging, incrementing a counter

```elixir
defmodule MyApp.Events.OrderAuditor do
  @behaviour Forja.Handler

  @impl true
  def event_types, do: :all

  @impl true
  def handle_event(%Forja.Event{} = event, _meta) do
    # Fast, local, unlikely to fail — no need for a separate worker
    MyApp.AuditLog.record(event.type, event.payload, event.source)
    :ok
  end
end
```

## Transactional emission from handlers

When a handler needs to both persist data and emit a new event atomically, use `emit_multi/4` inside the handler:

```elixir
defmodule MyApp.Events.PaymentProcessor do
  @behaviour Forja.Handler

  @impl true
  def event_types, do: ["order:created"]

  @impl true
  def handle_event(%Forja.Event{payload: payload}, _meta) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:users, fn _repo, _changes ->
      MyApp.Accounts.create_users_from_order(payload["order_id"])
    end)
    |> Forja.emit_multi(:my_app, MyApp.Events.UsersCreated,
      payload_fn: fn %{users: users} ->
        %{order_id: payload["order_id"], user_ids: Enum.map(users, & &1.id)}
      end
    )
    |> Forja.transaction(:my_app)
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end
```

The new `UsersCreated` event inherits the parent's `correlation_id` automatically (see the [Event Schemas guide](event-schemas.md#correlation--causation-ids)).

## Combining the patterns

A single handler can mix both approaches — emit events for domain reactions and enqueue workers for side effects:

```elixir
defmodule MyApp.Events.PaymentHandler do
  @behaviour Forja.Handler

  @impl true
  def event_types, do: ["payment:succeeded"]

  @impl true
  def handle_event(%Forja.Event{payload: payload}, _meta) do
    # 1. Domain reaction — emit event (with correlation propagation)
    Forja.emit(:my_app, MyApp.Events.ApplicationStatusChanged,
      payload: %{application_id: payload["application_id"], status: "paid"}
    )

    # 2. Side effect with retry — enqueue worker
    %{application_id: payload["application_id"]}
    |> MyApp.Workers.RequestDocuments.new()
    |> Oban.insert()

    # 3. Another side effect with retry
    %{application_id: payload["application_id"], template: "payment_confirmation"}
    |> MyApp.Workers.SendEmail.new(max_attempts: 10)
    |> Oban.insert()

    :ok
  end
end
```

## Reacting to failures with `on_failure/3`

When a handler fails, Forja calls the optional `on_failure/3` callback on the same handler module. This lets each handler decide how to react to its own failures — enqueue a retry, emit a compensating event, or alert.

```elixir
defmodule MyApp.Events.OrderNotifier do
  @behaviour Forja.Handler

  @impl true
  def event_types, do: ["order:created"]

  @impl true
  def handle_event(%Forja.Event{payload: payload}, _meta) do
    case MyApp.Mailer.send_confirmation(payload["email"]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def on_failure(%Forja.Event{} = event, {:error, :timeout}, _meta) do
    # Transient — enqueue a retry
    %{event_id: event.id, email: event.payload["email"]}
    |> MyApp.Workers.RetryEmail.new(max_attempts: 5)
    |> Oban.insert()
  end

  def on_failure(%Forja.Event{} = event, {:error, :invalid_email}, _meta) do
    # Permanent — alert, don't retry
    Sentry.capture_message("Invalid email for event #{event.id}")
  end

  def on_failure(_event, _reason, _meta), do: :ok
end
```

The `reason` argument is one of:

- `{:error, term()}` — the handler returned `{:error, reason}`
- `{:raised, Exception.t()}` — the handler raised an exception

If `on_failure/3` is not implemented, nothing extra happens — the failure is logged and `[:forja, :event, :failed]` telemetry is emitted as usual.

If `on_failure/3` itself raises, the exception is caught and logged. It does not affect other handlers or the event's processing status.

## Multi-step workflows with Sage

When a handler orchestrates multiple steps that need **compensation on failure** (undo previous steps if a later step fails), use [Sage](https://hex.pm/packages/sage) inside the handler. Forja delivers the event; Sage manages the transaction chain.

```elixir
defmodule MyApp.Events.IncorporationHandler do
  @behaviour Forja.Handler

  @impl true
  def event_types, do: ["payment:succeeded"]

  @impl true
  def handle_event(%Forja.Event{payload: payload}, _meta) do
    app_id = payload["application_id"]

    result =
      Sage.new()
      |> Sage.run(:create_users,
        fn _effects, _ -> MyApp.Accounts.create_from_application(app_id) end,
        fn users, _, _ -> MyApp.Accounts.delete_users(users) end
      )
      |> Sage.run(:update_status,
        fn _effects, _ -> MyApp.Applications.transition(app_id, :paid) end,
        fn _, _, _ -> MyApp.Applications.transition(app_id, :pending) end
      )
      |> Sage.run(:request_documents,
        fn _effects, _ -> MyApp.Zendesk.request_documents(app_id) end,
        fn _, _, _ -> :ok end
      )
      |> Sage.execute(%{})

    case result do
      {:ok, _effects} ->
        Forja.emit(:my_app, MyApp.Events.IncorporationStarted,
          payload: %{application_id: app_id}
        )
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def on_failure(%Forja.Event{payload: payload}, _reason, _meta) do
    Forja.emit(:my_app, MyApp.Events.IncorporationFailed,
      payload: %{application_id: payload["application_id"]}
    )
  end
end
```

The flow:

1. `PaymentSucceeded` triggers the handler
2. Sage runs 3 steps: create users → update status → request documents
3. If `request_documents` fails, Sage automatically reverses `update_status` and deletes the created users
4. The handler returns `{:error, reason}` → Forja calls `on_failure/3`
5. `on_failure/3` emits `IncorporationFailed` (with correlation inherited)
6. The entire chain is traceable via `correlation_id`

Sage is a separate dependency (`{:sage, "~> 0.6"}`). Forja does not depend on it — the integration happens naturally in handler code.

## DeadLetter: the last resort

`Forja.DeadLetter` is for a different scenario: the **event itself** could not be processed after all Oban retries or reconciliation attempts. This is the "end of the line" — the event bus gave up.

```elixir
defmodule MyApp.DeadLetterHandler do
  @behaviour Forja.DeadLetter

  @impl true
  def handle_dead_letter(%Forja.Event{} = event, reason) do
    Logger.error("Dead letter: #{event.type} (#{event.id}): #{inspect(reason)}")
    Sentry.capture_message("Event dead-lettered", extra: %{event_id: event.id})
    :ok
  end
end
```

| Callback | When it fires | Purpose |
|----------|--------------|---------|
| `on_failure/3` | A specific handler failed | Handler-level recovery (retry, compensate, alert) |
| `DeadLetter` | Oban discarded the job or reconciliation gave up | Event-level last resort (the bus gave up entirely) |

## Summary

| Scenario | Approach |
|----------|----------|
| Local, fast, unlikely to fail | Logic directly in handler |
| External service, can fail transiently | Dedicated Oban worker or `on_failure/3` retry |
| Multi-step with compensation | Sage inside handler |
| Domain reaction to event | `Forja.emit/3` inside handler |
| Data + event atomically | `Forja.emit_multi/4` inside handler |
| Handler-level failure recovery | `on_failure/3` callback |
| Event-level unrecoverable failure | `Forja.DeadLetter` behaviour |
