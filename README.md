# Forja

<img width="480" height="480" alt="forja-logo" src="https://github.com/user-attachments/assets/f064600a-7a80-478f-92bb-31ff1ecf418a" />


[![Hex.pm](https://img.shields.io/hexpm/v/forja.svg)](https://hex.pm/packages/forja)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/forja)
[![License](https://img.shields.io/hexpm/l/forja.svg)](LICENSE)

*Where events are forged into certainty.*

**Event Bus with Oban-backed processing for Elixir** -- persistent, exactly-once event delivery with PubSub notifications.

[Leia em Portugues](README.pt-BR.md)

---

## Why Forja?

> **Forja** (/ˈfɔʁ.ʒɐ/) -- Portuguese for *forge*. A forge shapes raw metal through fire and hammer into something reliable and enduring. Forja does the same with your events: Oban is the hammer that guarantees delivery, PubSub is the spark that notifies instantly, and what comes out is an event you can trust was processed exactly once.

Most event systems force a trade-off: **fast but unreliable** (PubSub) or **reliable but slow** (persistent queues). Forja gives you both -- Oban-backed persistence with PubSub best-effort notifications.

Every event is atomically persisted and enqueued:

- **Guaranteed processing** -- Oban persists the event and processes it as a background job with retries
- **Instant notification** -- PubSub broadcasts after commit for real-time subscribers (best-effort)

Three-layer deduplication (PostgreSQL advisory locks + `processed_at` column + Oban unique jobs) ensures **exactly-once processing**.

```
App Code
  |
  emit/3
  |
  +-- INSERT event + Oban job (single transaction)
  |
  +-- After commit: PubSub broadcast (best-effort notification)
  |
  +-- Oban polls -------> ProcessEventWorker
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
    {:forja, "~> 0.3.0"}
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

Compose event emission with your domain operations in a single database transaction using `Forja.emit_multi/4` and `Forja.transaction/2`:

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
  |> Forja.transaction(:my_app)
  |> case do
    {:ok, %{order: order}} -> {:ok, order}
    {:error, :order, changeset, _} -> {:error, changeset}
  end
end
```

`Forja.transaction/2` wraps `Ecto.Multi` and automatically broadcasts emitted events via PubSub after commit. You can also manually broadcast a previously emitted event with `Forja.broadcast_event/2`.

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

  # Optional: called when handle_event/2 fails or raises
  @impl Forja.Handler
  def on_failure(event, reason, _meta) do
    MyApp.Alerts.notify("Handler failed for #{event.type}: #{inspect(reason)}")
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

### Event schemas

Define typed, validated event contracts using `Forja.Event.Schema` with [Zoi](https://hexdocs.pm/zoi) validation:

```elixir
defmodule MyApp.Events.OrderCreated do
  use Forja.Event.Schema,
    event_type: "order:created",
    schema_version: 2,
    queue: :payments,       # routes to :forja_payments queue
    forja: :my_app,         # enables emit/1,2 and emit_multi/2,3
    source: "checkout"      # default source for emitted events

  payload do
    field :order_id, Zoi.string()
    field :amount_cents, Zoi.integer() |> Zoi.positive()
    field :currency, Zoi.string() |> Zoi.default("USD"), required: false
  end

  # Derive idempotency key from payload (default: nil)
  def idempotency_key(payload) do
    "order_created:#{payload["order_id"]}"
  end

  # Transform old payloads to current schema version
  def upcast(1, payload) do
    %{"order_id" => payload["order_id"],
      "amount_cents" => payload["total"],
      "currency" => "USD"}
  end
end
```

When `:forja` is provided, the schema module generates `emit/1,2` and `emit_multi/2,3` — so you can emit events directly from the schema:

```elixir
# All defaults (source, idempotency_key) come from the schema
MyApp.Events.OrderCreated.emit(%{order_id: "123", amount_cents: 5000})

# Override source per-call when needed
MyApp.Events.OrderCreated.emit(%{order_id: "123", amount_cents: 5000},
  source: "manual_payment"
)

# In an Ecto.Multi
Ecto.Multi.new()
|> Ecto.Multi.insert(:order, changeset)
|> MyApp.Events.OrderCreated.emit_multi(
  payload_fn: fn %{order: o} -> %{order_id: o.id, amount_cents: o.total} end
)
|> Forja.transaction(:my_app)
```

Schemas provide compile-time validation, runtime payload parsing via `parse_payload/1`, automatic upcasting from older versions, per-event queue routing, and centralized emission via `emit/1,2`.

### Correlation and causation

Forja automatically tracks event chains with correlation and causation IDs:

```elixir
# Root event gets an auto-generated correlation_id
{:ok, root} = Forja.emit(:my_app, "order:created",
  payload: %{"order_id" => "123"}
)

# Child events inherit correlation_id and set causation_id to parent
{:ok, child} = Forja.emit(:my_app, "payment:charged",
  payload: %{"order_id" => "123"},
  correlation_id: root.correlation_id,
  causation_id: root.id
)
```

This enables full event tracing across your system via `correlation_id` and `causation_id` columns.

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

  test "event causation chain" do
    {:ok, parent} = Forja.emit(:my_app, "order:created", payload: %{"id" => 1})
    {:ok, child} = Forja.emit(:my_app, "payment:charged",
      payload: %{"id" => 1},
      causation_id: parent.id,
      correlation_id: parent.correlation_id
    )

    assert_event_caused_by(:my_app, child.id, parent.id)
  end
end
```

## Telemetry

Forja ships with a built-in default logger you can opt into:

```elixir
Forja.Telemetry.attach_default_logger(:my_app, level: :info)
```

All telemetry events:

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
| `[:forja, :event, :validation_failed]` | Payload validation failed at emit-time |

For detailed telemetry metadata and custom handler examples, see the [Telemetry guide](https://hexdocs.pm/forja/telemetry.html).

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | *required* | Atom identifier for the Forja instance |
| `:repo` | *required* | Ecto.Repo module |
| `:pubsub` | *required* | Phoenix.PubSub module |
| `:oban_name` | `Oban` | Oban instance name |
| `:default_queue` | `:events` | Default Oban queue (resolves to `:forja_events`) |
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

## Guides

For in-depth documentation beyond this README:

- [Getting Started](https://hexdocs.pm/forja/getting-started.html) -- Step-by-step setup walkthrough
- [Architecture](https://hexdocs.pm/forja/architecture.html) -- Event lifecycle, idempotency, and supervision
- [Event Schemas](https://hexdocs.pm/forja/event-schemas.html) -- Typed contracts, versioning, and upcasting
- [Error Handling](https://hexdocs.pm/forja/error-handling.html) -- `on_failure/3`, Sage integration, dead letters
- [Telemetry](https://hexdocs.pm/forja/telemetry.html) -- Observability, custom handlers, and the default logger
- [Testing](https://hexdocs.pm/forja/testing.html) -- Test helpers and patterns
- [For Agents](https://hexdocs.pm/forja/for-agents.html) -- Step-by-step guide for AI coding agents

## License

MIT License. See [LICENSE](LICENSE) for details.
