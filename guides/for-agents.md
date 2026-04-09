# For Agents

A step-by-step implementation guide for AI coding agents integrating Forja into an Elixir application.

## Prerequisites checklist

Before starting, verify the target application has:

- [ ] Elixir 1.19+ (`elixir --version`)
- [ ] PostgreSQL as the database
- [ ] An `Ecto.Repo` module configured and working
- [ ] `Phoenix.PubSub` in the supervision tree
- [ ] `Oban` installed and configured (dependency + supervision tree)

If Oban is not yet installed, add it first:

```elixir
# mix.exs
{:oban, "~> 2.18"}
```

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10]
```

```elixir
# application.ex children list (after Repo)
{Oban, Application.fetch_env!(:my_app, Oban)}
```

## Step 1: Add the dependency

Add `forja` to `mix.exs`:

```elixir
def deps do
  [
    {:forja, "~> 0.4"}
  ]
end
```

Run `mix deps.get`.

## Step 2: Generate the migration

**Option A -- Igniter (preferred if available):**

```bash
mix igniter.install forja
```

This handles steps 2-4 automatically. Skip to Step 5 if using Igniter.

**Option B -- Manual:**

```bash
mix forja.install
mix ecto.migrate
```

This creates the `forja_events` table with the following columns: `id` (UUID), `type` (string), `payload` (map), `meta` (map), `source` (string), `processed_at` (utc_datetime_usec), `idempotency_key` (string), `reconciliation_attempts` (integer), `schema_version` (integer, default 1), `correlation_id` (binary_id), `causation_id` (binary_id), `inserted_at` (utc_datetime_usec).

**Verification:** Confirm the migration ran successfully and the `forja_events` table exists.

## Step 3: Configure Oban queues

Add the Forja queues to the existing Oban configuration in `config/config.exs`:

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

**Important rules:**

- Merge `forja_events` and `forja_reconciliation` into the existing `:queues` list -- do not overwrite other queues.
- The `forja_name` arg in the crontab **must match** the `:name` atom you will use in Step 4 (as a string). If the Forja name is `:my_app`, the arg is `"my_app"`.
- If `Oban.Plugins.Cron` is already configured, merge the new crontab entry into the existing list.
- The reconciliation crontab is optional but recommended for production.

**Verification:** Run `mix compile` to check for syntax errors in config files.

## Step 4: Add Forja to the supervision tree

In `application.ex`, add Forja to the children list **after** Repo, PubSub, and Oban:

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Oban, Application.fetch_env!(:my_app, Oban)},
  {Forja,
   name: :my_app,
   repo: MyApp.Repo,
   pubsub: MyApp.PubSub,
   handlers: []}
]
```

**Important rules:**

- The ordering matters. Forja depends on Repo, PubSub, and Oban being started first.
- `:name` is an atom identifier -- use the application name by convention.
- `:repo` must be the actual Repo module, not a string.
- `:pubsub` must be the PubSub module registered in the supervision tree.
- Start with `handlers: []` -- you will add handlers after creating them.

**Verification:** Run `mix compile`. Start the app with `iex -S mix` and confirm no startup errors.

## Step 5: Create an event handler

Create a handler module implementing the `Forja.Handler` behaviour:

```elixir
defmodule MyApp.Events.SomeHandler do
  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: ["some:event_type"]

  @impl Forja.Handler
  def handle_event(%Forja.Event{type: "some:event_type"} = event, _meta) do
    # Process the event here
    :ok
  end
end
```

**Rules for handlers:**

1. **Must return `:ok` or `{:error, reason}`** -- any other return value is treated as an error.
2. **Must be idempotent** -- the same event may be delivered more than once in edge cases (e.g., Oban retry after mark_processed failure). Design handlers so that processing the same event twice produces the same result.
3. **Do not perform long-running side effects inline** -- for operations that can fail independently (sending emails, calling external APIs), enqueue a separate Oban job from within the handler rather than doing it inline.
4. **Use pattern matching on event type** -- if the handler subscribes to multiple event types, use function clause pattern matching on `event.type`.
5. **Event types use `"namespace:action"` convention** -- e.g., `"order:created"`, `"user:registered"`, `"payment:refunded"`.
6. **Use `:all` to handle every event** -- return `:all` from `event_types/0` for catch-all handlers like audit loggers.
7. **Payload is a map with string keys** -- always access payload fields with string keys: `event.payload["field"]`, not `event.payload.field` or `event.payload[:field]`.

### Handler file location

Place handler modules in a context-appropriate namespace:

```
lib/my_app/events/order_notifier.ex
lib/my_app/events/analytics_tracker.ex
lib/my_app/events/audit_logger.ex
```

### Register the handler

Add the handler module to the `:handlers` list in the Forja supervision config:

```elixir
{Forja,
 name: :my_app,
 repo: MyApp.Repo,
 pubsub: MyApp.PubSub,
 handlers: [MyApp.Events.SomeHandler]}
```

**Verification:** Run `mix compile` to confirm the handler module is valid.

## Step 6: Emit events

### Simple emission

```elixir
Forja.emit(:my_app, MyApp.Events.OrderCreated,
  payload: %{"order_id" => order.id, "total" => order.total},
  source: "orders"
)
```

**Return values:**

- `{:ok, %Forja.Event{}}` -- event emitted successfully
- `{:ok, :already_processed}` -- idempotency key exists and event was already processed
- `{:ok, :retrying, event_id}` -- idempotency key exists but event hasn't been processed yet (re-enqueued)

### Transactional emission with Ecto.Multi

When the event must be atomic with a domain operation:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:order, Order.changeset(%Order{}, attrs))
|> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
  payload_fn: fn %{order: order} ->
    %{"order_id" => order.id, "total" => order.total}
  end,
  source: "orders"
)
|> Forja.transaction(:my_app)
```

**Important rules:**

- Use `emit_multi/4` when the event must succeed or fail with the domain operation.
- `payload_fn` receives the results of all previous Multi steps.
- The Oban job and event insert happen inside the same transaction.
- Call `Forja.transaction/2` on the Multi -- pass the Forja name as second argument.

### Idempotent emission

Use `idempotency_key` to prevent duplicate event processing:

```elixir
Forja.emit(:my_app, MyApp.Events.PaymentReceived,
  payload: %{"payment_id" => payment.id},
  idempotency_key: "payment-#{payment.id}"
)
```

Use idempotency keys when the same business event could trigger `emit/3` more than once (e.g., webhook retries, user double-clicks).

## Step 7: Add dead letter handling (optional but recommended)

Create a dead letter handler for events that exhaust all retry attempts:

```elixir
defmodule MyApp.Events.DeadLetterHandler do
  @behaviour Forja.DeadLetter

  @impl Forja.DeadLetter
  def handle_dead_letter(event, reason) do
    require Logger
    Logger.error("Dead letter: event #{event.id} (#{event.type}), reason: #{inspect(reason)}")
    :ok
  end
end
```

Register it in the Forja config:

```elixir
{Forja,
 name: :my_app,
 repo: MyApp.Repo,
 pubsub: MyApp.PubSub,
 handlers: [MyApp.Events.SomeHandler],
 dead_letter: MyApp.Events.DeadLetterHandler}
```

## Step 8: Set up telemetry (optional)

### Quick setup -- default logger

Add to `application.ex` **before** the children list:

```elixir
def start(_type, _args) do
  Forja.Telemetry.attach_default_logger(level: :info)

  children = [
    # ...
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Level options: `:debug` (everything), `:info` (lifecycle + problems), `:warning` (problems only), `:error` (critical only).

### Custom metrics

For StatsD, Prometheus, or other metrics backends, attach to telemetry events directly:

```elixir
:telemetry.attach_many(
  "forja-metrics",
  [
    [:forja, :event, :emitted],
    [:forja, :event, :processed],
    [:forja, :event, :failed],
    [:forja, :event, :dead_letter]
  ],
  &MyApp.ForjaMetrics.handle_event/4,
  nil
)
```

## Step 9: Write tests

Import `Forja.Testing` in test modules:

```elixir
defmodule MyApp.OrderTest do
  use MyApp.DataCase
  import Forja.Testing

  test "emitting order event" do
    {:ok, _order} = MyApp.Orders.create_order(%{total: 5000})

    assert_event_emitted(:my_app, MyApp.Events.OrderCreated, %{"total" => 5000})
  end

  test "process and verify side effects" do
    Forja.emit(:my_app, MyApp.Events.OrderCreated, payload: %{"order_id" => "123"})

    process_all_pending(:my_app)

    # Assert on handler side effects after synchronous processing
  end

  test "handler in isolation" do
    result = invoke_handler(
      MyApp.Events.OrderNotifier,
      "order:created",
      %{"order_id" => "123"}
    )

    assert result == :ok
  end
end
```

**Available test helpers:**

| Helper | Purpose |
|--------|---------|
| `assert_event_emitted/3` | Verify an event was persisted (supports partial payload matching) |
| `refute_event_emitted/2` | Verify no event of a type was emitted |
| `process_all_pending/1` | Synchronously process all unprocessed events |
| `assert_event_deduplicated/2` | Verify idempotency key has exactly one event |
| `invoke_handler/4` | Call a handler directly without persistence |

## Common mistakes to avoid

1. **String keys in payload, always.** Payloads are stored as JSON. Use `%{"order_id" => id}`, not `%{order_id: id}`. Atom keys will be converted to strings on storage and break pattern matches.

2. **Don't forget to register handlers.** Creating a handler module without adding it to the `:handlers` list means it will never receive events.

3. **Forja must start after its dependencies.** In the supervision tree, Forja must come after Repo, PubSub, and Oban. Starting it earlier will crash.

4. **The Forja name must be consistent.** The `:name` used in `Forja` supervision config, `Forja.emit/3`, `ReconciliationWorker` args, and test helpers must all match.

5. **Handlers must be idempotent.** In edge cases (e.g., Oban retry after a mark_processed failure), an event can be delivered to handlers more than once.

6. **Don't use `Repo.transaction` inside `emit/3`.** The `emit/3` function already runs in a transaction. If you need a transaction that includes both a domain operation and event emission, use `emit_multi/4`.

7. **Don't put Forja in a test-only conditional.** Forja should be in the supervision tree in all environments. In tests, use `Forja.Testing` helpers for synchronous processing.

8. **The `forja_name` in ReconciliationWorker crontab is a string**, not an atom. It must match the atom name as a string (`:my_app` -> `"my_app"`).

## Quick reference

### Full `application.ex` example

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Forja.Telemetry.attach_default_logger(level: :info)

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
         MyApp.Events.AuditLogger
       ],
       dead_letter: MyApp.Events.DeadLetterHandler}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Full `config/config.exs` Oban section

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

### Emit cheatsheet

```elixir
# Simple
Forja.emit(:name, MyApp.Events.TypeAction, payload: %{"key" => "value"}, source: "context")

# Idempotent
Forja.emit(:name, MyApp.Events.TypeAction, payload: %{...}, idempotency_key: "unique-key")

# Transactional
Multi.new()
|> Multi.insert(:record, changeset)
|> Forja.emit_multi(:name, MyApp.Events.TypeAction, payload_fn: fn %{record: r} -> %{"id" => r.id} end)
|> Forja.transaction(:name)
```

### Handler template

```elixir
defmodule MyApp.Events.NameHandler do
  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: ["namespace:action"]

  @impl Forja.Handler
  def handle_event(%Forja.Event{type: "namespace:action"} = event, _meta) do
    # Access payload with string keys: event.payload["key"]
    # Return :ok or {:error, reason}
    :ok
  end
end
```
