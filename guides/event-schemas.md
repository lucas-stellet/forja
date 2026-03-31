# Event Schemas

Forja's event schemas bring contract-first design to your event bus. Define the shape of each event's payload once, get validation at emit time, and migrate old events forward as your domain evolves.

## 1. Why event contracts matter

In an event-driven architecture, the **only** thing shared between the producer and any consumer is the message itself. As Mathias Verraes put it: _"the only thing shared between emitter and receiver is the message."_ When that message has no enforced contract, the system develops cracks silently:

- A producer renames a field — handlers that depend on it break with no warning
- Payload drift accumulates across callers as each one interprets the shape differently
- There is no discoverability — you cannot ask "what fields does this event carry?"
- Consumers write defensive code to handle missing or malformed fields, spreading implicit assumptions throughout the codebase

The anti-pattern of generic events without clear intent — where a single "application_updated" event carries no specific business intent — is a direct consequence of skipping contracts. An event like `"application_updated"` tells you nothing about what changed, while `PaymentSucceeded` with a typed payload carries both intent and structure.

Forja solves this with `Forja.Event.Schema`, which lets you define a Zoi-validated payload schema per event type. Emitting through a schema module fails fast at the call site if the payload is malformed, before it ever reaches the bus.

A related concern is Event-Carried State Transfer: when your event payload carries all the data the handler needs, you are coupling the producer and consumer by the payload shape. Without versioning and upcasting, that coupling becomes a liability the moment the schema needs to evolve.

## 2. Defining an event schema

Define a schema module for each event type using `Forja.Event.Schema`:

```elixir
defmodule MyApp.Events.OrderCreated do
  use Forja.Event.Schema

  event_type "order:created"
  schema_version 1

  payload do
    field :order_id, Zoi.string()
    field :user_id, Zoi.string()
    field :amount_cents, Zoi.integer() |> Zoi.positive()
    field :currency, Zoi.string() |> Zoi.default("USD"), required: false
    field :tags, Zoi.list(Zoi.string()), required: false
  end
end
```

**`event_type/1`** sets the string identifier for this event. This is the value consumers subscribe to.

**`schema_version/1`** sets the schema version (defaults to 1 if omitted). Increment this when the payload shape changes in a breaking way.

**`queue/1`** sets the Oban queue for this event type. Forja prefixes the name with `forja_` internally. Optional — when omitted, the event uses the `default_queue` from the Forja config (default: `:events`, resolves to `:forja_events`).

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

**`payload do ... end`** declares the fields using Zoi types:

| Zoi type | Description |
|-----------|-------------|
| `Zoi.string()` | String value |
| `Zoi.integer()` | Integer value |
| `Zoi.list(type)` | List of the given type |
| `Zoi.default(value)` | Provides a default when the field is absent (use with optional fields) |
| `Zoi.positive()` | Refinement — integer must be greater than zero |
| `Zoi.min(n)` | Refinement — string/integer/list must have min length/value of `n` |

Fields are **required by default**. Mark a field as optional with `required: false`:

```elixir
payload do
  field :order_id, Zoi.string()
  field :notes, Zoi.string(), required: false
end
```

## 3. Emitting validated events

Use the schema module as the second argument to `Forja.emit/3`:

```elixir
Forja.emit(:my_app, MyApp.Events.OrderCreated,
  payload: %{
    "order_id" => "ord-123",
    "user_id" => "usr-456",
    "amount_cents" => 4999
  }
)
```

`emit/3` calls `MyApp.Events.OrderCreated.parse_payload/1` internally. If validation fails, emission is rejected and returns an error:

```elixir
{:error, {:validation, errors}}
```

Where `errors` is the Zoi validation error list describing which fields were missing or invalid.

Defaults are applied during parsing — the `currency` field in the example above defaults to `"USD"` even though it was not provided in the payload.

**`emit_multi/4`** also works with schema modules:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:order, order_changeset)
|> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
  payload_fn: fn %{order: order} -> %{
    "order_id" => order.id,
    "user_id" => order.user_id,
    "amount_cents" => order.total_cents
  } end
)
|> Forja.transaction(:my_app)
```

The payload is validated before the event is inserted into the database. If validation fails, the multi fails and the transaction rolls back.

## 4. Why versioning matters

Persistent event stores keep old events in the database indefinitely. When you replay those events against new handlers, the handlers expect the current payload shape — but the stored payload reflects the shape at the time of emission.

Consider this timeline:

1. `OrderCreated v1` is emitted with `{"total": 4999, "currency": "USD"}`
2. The domain team decides to split `total` into `subtotal_cents` and `tax_cents`
3. `OrderCreated v2` is emitted with the new fields
4. A reconciliation run picks up old v1 events — handlers expecting v2 fields crash or misbehave

Event-Carried State Transfer requires careful versioning precisely because the payload is the only thing the consumer has access to. Without a versioning strategy, schema evolution breaks replay and reconciliation.

## 5. How versioning works

Every schema module carries a `schema_version` integer. When an event is persisted, this integer is stored in the `forja_events.schema_version` column. The original payload is **never modified** in the database.

`upcast/2` transforms an old payload in memory so that handlers always receive the current shape:

```elixir
defmodule MyApp.Events.OrderCreated do
  use Forja.Event.Schema

  event_type "order:created"
  schema_version 2

  payload do
    field :order_id, Zoi.string(), required: true
    field :user_id, Zoi.string(), required: true
    field :subtotal_cents, Zoi.integer() |> Zoi.positive(), required: true
    field :tax_cents, Zoi.integer() |> Zoi.positive(), required: true
    field :currency, Zoi.string() |> Zoi.default("USD")
  end

  def upcast(1, payload) do
    # v1 had a single "total" field — split it into subtotal + tax
    total = payload["total"]
    tax = div(total * 10, 100)  # 10% tax
    %{
      "order_id" => payload["order_id"],
      "user_id" => payload["user_id"],
      "subtotal_cents" => total - tax,
      "tax_cents" => tax
    }
  end
end
```

When an event with `schema_version: 1` is read from the database, Forja calls `upcast(1, payload)` and passes the transformed payload to handlers. The original record in the database is unchanged.

**When to increment `schema_version`:**
- Renaming or removing a field
- Changing a field's type
- Making a required field optional (a consumer that expects it may break)

**When not to increment:**
- Adding a new optional field with a default — old payloads will parse successfully and handlers that ignore the new field continue to work

**Upcasting chain:** If you go from v1 → v2 → v3, implement `upcast/2` for each transition. Forja calls `upcast` with the stored version number, not necessarily `version - 1`, so each function must handle the full transformation from that version.

## 6. Relationship with handlers

Handlers receive `Forja.Event` structs regardless of how the event was emitted. A schema-validated event produces the same `Forja.Event` shape as an untyped event — the only difference is that the `payload` field is guaranteed to have passed Zoi validation when it was emitted.

```elixir
defmodule MyApp.Events.OrderNotifier do
  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: ["order:created"]

  @impl Forja.Handler
  def handle_event(%Forja.Event{type: "order:created"} = event, _meta) do
    # event.payload is guaranteed to match OrderCreated's schema
    IO.puts("Order created: #{event.payload["order_id"]}")
    :ok
  end
end
```

Every event emitted through Forja is validated against its schema module, so handlers can trust the payload structure.

## 7. Dependency note

`Forja.Event.Schema` depends on [Zoi](https://hex.pm/zoi). Zoi is listed as an **optional** dependency in Forja's `mix.exs`:

```elixir
{:zoi, "~> 0.17", optional: true}
```

Zoi is a required dependency of Forja — it is pulled in automatically when you add `{:forja, "~> 0.2"}` to your deps.

## 8. Correlation & Causation IDs

Every event emitted through Forja carries two identifying fields:

- **`correlation_id`** — A UUID that groups all events belonging to the same logical operation or transaction. When a handler emits a child event, the child inherits the parent's `correlation_id`, allowing you to trace an entire chain of events back to a single origin.

- **`causation_id`** — The UUID of the event that directly caused this one. Root events (emitted directly by application code) have `nil` causation_id. When a handler emits a child event, the child's `causation_id` is set to the parent's event ID.

### How propagation works

When you call `Forja.emit/3` inside a handler, Forja automatically sets the `correlation_id` and `causation_id` on the child event:

```elixir
# Inside a handler for "order:created"
def handle_event(%Forja.Event{} = event, _meta) do
  # child inherits event.correlation_id and sets causation_id to event.id
  {:ok, child} = Forja.emit(:my_app, MyApp.Events.OrderNotified, payload: %{...})
  :ok
end
```

The parent event's `correlation_id` becomes the child's `correlation_id`. The parent's `id` becomes the child's `causation_id`.

**Handlers do not need to do anything special** — the propagation happens automatically based on the event currently being processed. Each new root event gets a fresh `correlation_id`.

### Tracing chains in SQL

To find all events in a single correlation chain:

```sql
SELECT id, type, correlation_id, causation_id, inserted_at
FROM forja_events
WHERE correlation_id = 'your-correlation-uuid-here'
ORDER BY inserted_at;
```

To find all events directly caused by a specific event:

```sql
SELECT id, type, correlation_id, causation_id, inserted_at
FROM forja_events
WHERE causation_id = 'your-event-id-here';
```

To reconstruct the full parent→child tree for a correlation:

```sql
SELECT
  child.id AS child_id,
  child.type AS child_type,
  parent.id AS parent_id,
  parent.type AS parent_type,
  child.inserted_at
FROM forja_events child
JOIN forja_events parent ON parent.id = child.causation_id
WHERE child.correlation_id = 'your-correlation-uuid-here'
ORDER BY child.inserted_at;
```
