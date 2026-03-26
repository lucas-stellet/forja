# Forja

[![Hex.pm](https://img.shields.io/hexpm/v/forja.svg)](https://hex.pm/packages/forja)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/forja)
[![License](https://img.shields.io/hexpm/l/forja.svg)](LICENSE)

**Event Bus com processamento dual-path para Elixir** -- latencia de PubSub com garantias de entrega do Oban.

[Read in English](README.md)

---

## Por que Forja?

A maioria dos sistemas de eventos forca uma escolha: **rapido mas nao confiavel** (PubSub) ou **confiavel mas lento** (filas persistentes). Forja entrega os dois.

Cada evento percorre dois caminhos simultaneamente:

- **Caminho rapido** -- GenStage via PubSub entrega eventos em milissegundos
- **Caminho garantido** -- Oban persiste o evento e processa como job em background

Deduplicacao em tres camadas (advisory locks do PostgreSQL + coluna `processed_at` + jobs unicos do Oban) garante **processamento exactly-once** independente de qual caminho vencer.

```
Codigo da App
  |
  emit/3
  |
  +-- INSERT evento + Oban job (transacao unica)
  |
  +-- PubSub broadcast ---------> GenStage pipeline (rapido)
  |                                    |
  +-- Oban polls -------> ProcessEventWorker (garantido)
                                       |
                          advisory lock + check processed_at
                                       |
                               Handler.handle_event/2
```

## Instalacao

Adicione `forja` nas dependencias do `mix.exs`:

```elixir
def deps do
  [
    {:forja, "~> 0.1.0"}
  ]
end
```

### Com Igniter (recomendado)

Se voce tem o [Igniter](https://hexdocs.pm/igniter) instalado:

```bash
mix igniter.install forja
```

Isso gera a migration automaticamente, adiciona Forja na supervision tree e configura as filas do Oban.

### Setup manual

1. Gere a migration:

```bash
mix forja.install
mix ecto.migrate
```

2. Configure as filas do Oban em `config/config.exs`:

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

3. Adicione Forja na supervision tree:

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

## Uso

### Emitindo eventos

```elixir
# Emissao simples
Forja.emit(:my_app, "order:created",
  payload: %{"order_id" => order.id, "total" => order.total},
  source: "orders"
)

# Emissao idempotente (previne processamento duplicado)
Forja.emit(:my_app, "payment:received",
  payload: %{"payment_id" => payment.id},
  idempotency_key: "payment-#{payment.id}"
)
```

### Emissao transacional

Componha emissao de eventos com operacoes do dominio em uma unica transacao:

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

### Escrevendo handlers

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

Use `:all` para capturar todos os tipos de evento:

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

Quando um evento esgota todas as tentativas de processamento, Forja pode notificar voce:

```elixir
defmodule MyApp.Events.DeadLetterHandler do
  @behaviour Forja.DeadLetter

  @impl Forja.DeadLetter
  def handle_dead_letter(event, reason) do
    MyApp.Alerts.notify_ops("Evento dead letter", %{
      event_id: event.id,
      type: event.type,
      reason: reason
    })
    :ok
  end
end
```

## Testes

Forja fornece helpers de teste para verificar emissao de eventos:

```elixir
defmodule MyApp.OrderTest do
  use MyApp.DataCase
  import Forja.Testing

  test "emite evento de pedido" do
    {:ok, _order} = MyApp.Orders.create_order(%{total: 5000})

    assert_event_emitted(:my_app, "order:created", %{"total" => 5000})
  end

  test "processa eventos pendentes sincronamente" do
    Forja.emit(:my_app, "order:created", payload: %{"id" => 1})

    process_all_pending(:my_app)

    # Todos os handlers ja executaram
  end
end
```

## Telemetria

| Evento | Significado |
|--------|-------------|
| `[:forja, :event, :emitted]` | Evento persistido e broadcast enviado |
| `[:forja, :event, :processed]` | Handler processou com sucesso (inclui duracao) |
| `[:forja, :event, :failed]` | Handler retornou erro ou lancou excecao |
| `[:forja, :event, :skipped]` | Advisory lock ja estava em uso |
| `[:forja, :event, :dead_letter]` | Oban descartou o job |
| `[:forja, :event, :abandoned]` | Reconciliacao esgotou tentativas |
| `[:forja, :event, :reconciled]` | Reconciliacao processou evento pendente |
| `[:forja, :event, :deduplicated]` | Chave de idempotencia preveniu duplicata |

## Licenca

MIT License. Veja [LICENSE](LICENSE) para detalhes.
