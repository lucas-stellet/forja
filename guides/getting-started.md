# Getting Started

This guide walks you through installing Forja, emitting your first event, and writing your first handler.

## Prerequisites

- Elixir 1.19+
- PostgreSQL
- An existing Phoenix or Elixir application with Ecto and Oban configured

## Step 1: Install Forja

Add `forja` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:forja, "~> 0.3.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Step 2: Generate the migration

```bash
mix forja.install
mix ecto.migrate
```

This creates the `forja_events` table with all necessary indexes.

> If you have [Igniter](https://hexdocs.pm/igniter) installed, `mix igniter.install forja` handles steps 2-4 automatically.

## Step 3: Configure Oban queues

In your `config/config.exs`, add the Forja queues to your Oban configuration:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    default: 10,
    forja_events: 5,
    forja_reconciliation: 1
  ]
```

Optionally, add the reconciliation worker to the crontab:

```elixir
plugins: [
  {Oban.Plugins.Cron, crontab: [
    {"0 * * * *", Forja.Workers.ReconciliationWorker,
     args: %{forja_name: "my_app"}}
  ]}
]
```

## Step 4: Add Forja to your supervision tree

In your `application.ex`, add Forja **after** Repo, PubSub, and Oban:

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

## Step 5: Write your first handler

Create a handler module that implements the `Forja.Handler` behaviour:

```elixir
defmodule MyApp.Events.OrderNotifier do
  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: ["order:created"]

  @impl Forja.Handler
  def handle_event(%Forja.Event{type: "order:created"} = event, _meta) do
    IO.puts("Order created: #{event.payload["order_id"]}")
    :ok
  end
end
```

Register it in your Forja configuration:

```elixir
{Forja,
 name: :my_app,
 repo: MyApp.Repo,
 pubsub: MyApp.PubSub,
 handlers: [MyApp.Events.OrderNotifier]}
```

## Step 6: Emit your first event

```elixir
Forja.emit(:my_app, MyApp.Events.OrderCreated,
  payload: %{order_id: "12345", total: 4999},
  source: "orders"
)
```

Oban will process the event and dispatch it to your handler.

## Next steps

- Read the [Architecture guide](architecture.md) to understand the Oban-based architecture
- Learn about [Telemetry events](telemetry.md) for observability
- Check the [Testing guide](testing.md) for verifying event emission in tests
