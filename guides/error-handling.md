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
    |> MyApp.Repo.transaction()
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

## Automatic DeadLetter notification on handler failure

When any handler returns `{:error, reason}` or raises an exception, Forja automatically calls the configured `DeadLetter` callback with the failure details. The reason tuple includes the handler module so you can distinguish which handler failed:

- `{:handler_failed, MyApp.OrderNotifier, :timeout}` — handler returned an error
- `{:handler_raised, MyApp.OrderNotifier, %RuntimeError{}}` — handler raised an exception

This happens **in addition to** the telemetry event and log. You don't need to do anything extra — just configure a `DeadLetter` module and it receives all handler failures automatically.

## Using DeadLetter for alerting and recovery

Configure a `DeadLetter` module to react to handler failures:

```elixir
defmodule MyApp.DeadLetterHandler do
  @behaviour Forja.DeadLetter

  require Logger

  @impl true
  def handle_dead_letter(%Forja.Event{} = event, {:handler_failed, handler, reason}) do
    Logger.error("Handler #{inspect(handler)} failed for #{event.type}: #{inspect(reason)}")
    Sentry.capture_message("Handler failed",
      extra: %{event_id: event.id, handler: inspect(handler), reason: inspect(reason)}
    )
    :ok
  end

  def handle_dead_letter(%Forja.Event{} = event, {:handler_raised, handler, exception}) do
    Logger.error("Handler #{inspect(handler)} raised for #{event.type}: #{Exception.message(exception)}")
    Sentry.capture_exception(exception,
      extra: %{event_id: event.id, handler: inspect(handler)}
    )
    :ok
  end

  def handle_dead_letter(%Forja.Event{} = event, reason) do
    Logger.error("Dead letter: #{event.type} (#{event.id}): #{inspect(reason)}")
    :ok
  end
end
```

Configure it in the Forja supervision tree:

```elixir
{Forja,
 name: :my_app,
 repo: MyApp.Repo,
 pubsub: MyApp.PubSub,
 handlers: [MyApp.Events.PaymentHandler],
 dead_letter: MyApp.DeadLetterHandler}
```

## Summary

| Scenario | Approach |
|----------|----------|
| Local, fast, unlikely to fail | Logic directly in handler |
| External service, can fail transiently | Dedicated Oban worker |
| Domain reaction to event | `Forja.emit/3` inside handler |
| Data + event atomically | `Forja.emit_multi/4` inside handler |
| Unrecoverable failure | `Forja.DeadLetter` behaviour |
