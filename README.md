# Forja

[![Hex.pm](https://img.shields.io/hexpm/v/forja.svg)](https://hex.pm/packages/forja)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/forja)
[![License](https://img.shields.io/hexpm/l/forja.svg)](LICENSE)

**Event Bus with dual-path processing for Elixir** -- PubSub latency with Oban delivery guarantees.

[Leia em Portugues](README.pt-BR.md)

---

## Why Forja?

Most event systems force a trade-off: **fast but unreliable** (PubSub) or **reliable but slow** (persistent queues). Forja gives you both.

Every event travels two paths simultaneously:

- **Fast path** -- GenStage via PubSub delivers events in milliseconds
- **Guaranteed path** -- Oban persists the event and processes it as a background job

Three-layer deduplication (PostgreSQL advisory locks + `processed_at` column + Oban unique jobs) ensures **exactly-once processing** regardless of which path wins.

```
App Code
  |
  emit/3
  |
  +-- INSERT event + Oban job (single transaction)
  |
  +-- PubSub broadcast ---------> GenStage pipeline (fast)
  |                                    |
  +-- Oban polls -------> ProcessEventWorker (guaranteed)
                                       |
                          advisory lock + processed_at check
                                       |
                               Handler.handle_event/2
```

## Installation

Add `forja` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:forja, "~> 0.1.0"}
  ]
end
```

### With Igniter (recommended)

If you have [Igniter](https://hexdocs.pm/igniter) installed, run:

```bash
mix igniter.install forja
```

This automatically generates the migration, adds Forja to your supervision tree, and configures Oban queues.

### Manual setup

1. Generate the migration:

```bash
mix forja.install
mix ecto.migrate
```

2. Configure Oban queues in `config/config.exs`:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,
    forja_events: 5,
    forja_reconciliation: 1
  ],
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"0 * * * *", Forja.Workers.ReconciliationWorker,
       args: %{forja_name: "my_app"}}
    ]}
  ]
```

3. Add Forja to your supervision tree:

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Oban, Application.fetch_env!(:my_app, Oban)},
  {Forja,
   name: :my_app,
   repo: MyApp.Repo,
   pubsub: MyApp.PubSub,
   handlers: [
     MyApp.Events.OrderNotifier,
     MyApp.Events.AnalyticsTracker
   ]}
]
```

## Usage

### Emitting events

```elixir
# Simple emission
Forja.emit(:my_app, "order:created",
  payload: %{"order_id" => order.id, "total" => order.total},
  source: "orders"
)

# Idempotent emission (prevents duplicate processing)
Forja.emit(:my_app, "payment:received",
  payload: %{"payment_id" => payment.id},
  idempotency_key: "payment-#{payment.id}"
)
```

### Transactional emission

Compose event emission with your domain operations in a single database transaction:

```elixir
def create_order(attrs) do
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:order, Order.changeset(%Order{}, attrs))
  |> Forja.emit_multi(:my_app, "order:created",
    payload_fn: fn %{order: order} ->
      %{"order_id" => order.id, "total" => order.total}
    end,
    source: "orders"
  )
  |> Repo.transaction()
  |> case do
    {:ok, %{order: order}} -> {:ok, order}
    {:error, :order, changeset, _} -> {:error, changeset}
  end
end
```

### Writing handlers

```elixir
defmodule MyApp.Events.OrderNotifier do
  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: ["order:created", "order:shipped"]

  @impl Forja.Handler
  def handle_event(%Forja.Event{type: "order:created"} = event, _meta) do
    order = MyApp.Orders.get_order!(event.payload["order_id"])
    MyApp.Mailer.send_confirmation(order)
    :ok
  end

  def handle_event(%Forja.Event{type: "order:shipped"} = event, _meta) do
    order = MyApp.Orders.get_order!(event.payload["order_id"])
    MyApp.Mailer.send_shipping_notification(order)
    :ok
  end
end
```

Use `:all` to handle every event type:

```elixir
defmodule MyApp.Events.AuditLogger do
  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: :all

  @impl Forja.Handler
  def handle_event(event, _meta) do
    MyApp.AuditLog.record(event.type, event.payload)
    :ok
  end
end
```

### Dead letter handling

When an event exhausts all processing attempts, Forja can notify you:

```elixir
defmodule MyApp.Events.DeadLetterHandler do
  @behaviour Forja.DeadLetter

  @impl Forja.DeadLetter
  def handle_dead_letter(event, reason) do
    MyApp.Alerts.notify_ops("Dead letter event", %{
      event_id: event.id,
      type: event.type,
      reason: reason
    })
    :ok
  end
end

# Configure in supervision tree:
{Forja,
 name: :my_app,
 repo: MyApp.Repo,
 pubsub: MyApp.PubSub,
 handlers: [...],
 dead_letter: MyApp.Events.DeadLetterHandler}
```

## Testing

Forja provides test helpers for verifying event emission:

```elixir
defmodule MyApp.OrderTest do
  use MyApp.DataCase
  import Forja.Testing

  test "emitting order event" do
    {:ok, _order} = MyApp.Orders.create_order(%{total: 5000})

    assert_event_emitted(:my_app, "order:created", %{"total" => 5000})
  end

  test "no duplicate events" do
    MyApp.Orders.create_order(%{total: 5000})

    assert_event_deduplicated(:my_app, "order-create-ref-123")
  end

  test "process pending events synchronously" do
    Forja.emit(:my_app, "order:created", payload: %{"id" => 1})

    process_all_pending(:my_app)

    # All handlers have now executed
  end
end
```

## Telemetry

Forja emits telemetry events for observability:

| Event | Meaning |
|-------|---------|
| `[:forja, :event, :emitted]` | Event persisted and broadcast |
| `[:forja, :event, :processed]` | Handler processed successfully (includes duration) |
| `[:forja, :event, :failed]` | Handler returned error or raised |
| `[:forja, :event, :skipped]` | Advisory lock already held |
| `[:forja, :event, :dead_letter]` | Oban discarded the job |
| `[:forja, :event, :abandoned]` | Reconciliation exhausted retries |
| `[:forja, :event, :reconciled]` | Reconciliation processed a stale event |
| `[:forja, :event, :deduplicated]` | Idempotency key prevented duplicate |

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | *required* | Atom identifier for the Forja instance |
| `:repo` | *required* | Ecto.Repo module |
| `:pubsub` | *required* | Phoenix.PubSub module |
| `:oban_name` | `Oban` | Oban instance name |
| `:consumer_pool_size` | `4` | Max concurrent GenStage event processing |
| `:event_topic_prefix` | `"forja"` | PubSub topic prefix |
| `:handlers` | `[]` | List of `Forja.Handler` modules |
| `:dead_letter` | `nil` | Module implementing `Forja.DeadLetter` |
| `:reconciliation` | see below | Reconciliation settings |

### Reconciliation defaults

```elixir
reconciliation: [
  enabled: true,
  interval_minutes: 60,
  threshold_minutes: 15,
  max_retries: 3
]
```

## Architecture

Forja runs as a supervisor with three children:

- **ObanListener** -- Watches for discarded Oban jobs to trigger dead letter handling
- **EventProducer** -- GenStage producer that receives PubSub broadcasts and buffers event IDs
- **EventConsumer** -- ConsumerSupervisor that spawns a transient Task per event

The **Processor** is the shared functional core called by both paths. It acquires an advisory lock, loads the event, dispatches to handlers, and marks the event as processed.

Two Oban workers run outside the supervision tree:

- **ProcessEventWorker** -- Queue `:forja_events`, the guaranteed delivery path
- **ReconciliationWorker** -- Queue `:forja_reconciliation`, periodic sweep for stale events

## License

MIT License. See [LICENSE](LICENSE) for details.
