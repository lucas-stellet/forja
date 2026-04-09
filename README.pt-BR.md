# Forja

<img width="480" height="480" alt="forja-logo" src="https://github.com/user-attachments/assets/f064600a-7a80-478f-92bb-31ff1ecf418a" />


[![Hex.pm](https://img.shields.io/hexpm/v/forja.svg)](https://hex.pm/packages/forja)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/forja)
[![License](https://img.shields.io/hexpm/l/forja.svg)](LICENSE)

*Onde eventos sao forjados em certeza.*

**Event Bus com processamento Oban-backed para Elixir** -- entrega de eventos persistente e exactly-once com notificacoes PubSub.

[Read in English](README.md)

---

## Por que Forja?

> **Forja** (/ˈfɔʁ.ʒɐ/) -- portugues para *forge*. Uma forja transforma metal bruto em algo confiavel e duradouro atraves do fogo e do martelo. Forja faz o mesmo com seus eventos: Oban e o martelo que garante a entrega, PubSub e a fagulha que notifica instantaneamente, e o que sai e um evento que voce pode confiar que foi processado exatamente uma vez.

A maioria dos sistemas de eventos forca uma escolha: **rapido mas nao confiavel** (PubSub) ou **confiavel mas lento** (filas persistentes). Forja entrega os dois -- persistencia via Oban com notificacoes best-effort via PubSub.

Cada evento e persistido e enfileirado atomicamente:

- **Processamento garantido** -- Oban persiste o evento e processa como job em background com retentativas
- **Notificacao instantanea** -- PubSub faz broadcast apos o commit para assinantes em tempo real (best-effort)

Deduplicacao em duas camadas (coluna `processed_at` + jobs unicos do Oban) garante **processamento exactly-once**.

```
Codigo da App
  |
  emit/3
  |
  +-- INSERT evento + Oban job (transacao unica)
  |
  +-- Apos commit: PubSub broadcast (notificacao best-effort)
  |
  +-- Oban polls -------> ProcessEventWorker
                                  |
                     processed_at + Oban unique check
                                  |
                          Handler.handle_event/2
```

## Instalacao

Adicione `forja` nas dependencias do `mix.exs`:

```elixir
def deps do
  [
    {:forja, "~> 0.4"}
  ]
end
```

### Com Igniter (recomendado)

Se voce tem o [Igniter](https://hexdocs.pm/igniter) instalado, execute:

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
# Emissao simples com modulo de schema
Forja.emit(:my_app, MyApp.Events.OrderCreated,
  payload: %{order_id: order.id, amount_cents: order.total},
  source: "orders"
)

# Emissao idempotente (previne processamento duplicado)
Forja.emit(:my_app, MyApp.Events.PaymentReceived,
  payload: %{payment_id: payment.id},
  idempotency_key: "payment-#{payment.id}"
)
```

### Emissao transacional

Componha emissao de eventos com operacoes do dominio em uma unica transacao usando `Forja.emit_multi/4` e `Forja.transaction/2`:

```elixir
def create_order(attrs) do
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:order, Order.changeset(%Order{}, attrs))
  |> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
    payload_fn: fn %{order: order} ->
      %{order_id: order.id, amount_cents: order.total}
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

`Forja.transaction/2` encapsula `Ecto.Multi` e automaticamente faz broadcast dos eventos emitidos via PubSub apos o commit. Voce tambem pode fazer broadcast manual de um evento previamente emitido com `Forja.broadcast_event/2`.

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

  # Opcional: chamado quando handle_event/2 falha ou lanca excecao
  @impl Forja.Handler
  def on_failure(event, reason, _meta) do
    MyApp.Alerts.notify("Handler falhou para #{event.type}: #{inspect(reason)}")
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

### Event schemas

Defina contratos de eventos tipados e validados usando `Forja.Event.Schema` com validacao [Zoi](https://hexdocs.pm/zoi):

```elixir
defmodule MyApp.Events.OrderCreated do
  use Forja.Event.Schema,
    event_type: "order:created",
    schema_version: 2,
    queue: :payments,       # roteia para a fila :forja_payments
    forja: :my_app,         # habilita emit/1,2 e emit_multi/1,2
    source: "checkout"      # source padrao para eventos emitidos

  payload do
    field :order_id, Zoi.string()
    field :amount_cents, Zoi.integer() |> Zoi.positive()
    field :currency, Zoi.string() |> Zoi.default("USD"), required: false
  end

  # Deriva chave de idempotencia a partir do payload (padrao: nil)
  def idempotency_key(payload) do
    "order_created:#{payload["order_id"]}"
  end

  # Transforma payloads antigos para a versao atual do schema
  def upcast(1, payload) do
    %{"order_id" => payload["order_id"],
      "amount_cents" => payload["total"],
      "currency" => "USD"}
  end
end
```

Quando `:forja` e fornecido, o modulo de schema gera `emit/1,2` e `emit_multi/1,2` -- assim voce pode emitir eventos diretamente pelo schema:

```elixir
# Todos os defaults (source, idempotency_key) vem do schema
MyApp.Events.OrderCreated.emit(%{order_id: "123", amount_cents: 5000})

# Sobrescreva source por chamada quando necessario
MyApp.Events.OrderCreated.emit(%{order_id: "123", amount_cents: 5000},
  source: "manual_payment"
)

# Dentro de um Ecto.Multi
Ecto.Multi.new()
|> Ecto.Multi.insert(:order, changeset)
|> MyApp.Events.OrderCreated.emit_multi(
  payload_fn: fn %{order: o} -> %{order_id: o.id, amount_cents: o.total} end
)
|> Forja.transaction(:my_app)
```

Schemas fornecem validacao em tempo de compilacao, parsing de payload em tempo de execucao via `parse_payload/1`, upcasting automatico de versoes anteriores, roteamento de fila por evento e emissao centralizada via `emit/1,2`.

### Correlacao e causacao

Forja rastreia automaticamente cadeias de eventos com IDs de correlacao e causacao:

```elixir
# Evento raiz recebe um correlation_id gerado automaticamente
{:ok, root} = Forja.emit(:my_app, MyApp.Events.OrderCreated,
  payload: %{order_id: "123"}
)

# Eventos filhos herdam correlation_id e definem causation_id para o pai
{:ok, child} = Forja.emit(:my_app, MyApp.Events.PaymentCharged,
  payload: %{order_id: "123"},
  correlation_id: root.correlation_id,
  causation_id: root.id
)
```

Isso habilita rastreamento completo de eventos pelo sistema via as colunas `correlation_id` e `causation_id`.

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

# Configure na supervision tree:
{Forja,
 name: :my_app,
 repo: MyApp.Repo,
 pubsub: MyApp.PubSub,
 handlers: [...],
 dead_letter: MyApp.Events.DeadLetterHandler}
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

  test "sem eventos duplicados" do
    MyApp.Orders.create_order(%{total: 5000})

    assert_event_deduplicated(:my_app, "order-create-ref-123")
  end

  test "processa eventos pendentes sincronamente" do
    Forja.emit(:my_app, MyApp.Events.OrderCreated, payload: %{id: 1})

    process_all_pending(:my_app)

    # Todos os handlers ja executaram
  end

  test "cadeia de causacao de eventos" do
    {:ok, parent} = Forja.emit(:my_app, MyApp.Events.OrderCreated, payload: %{id: 1})
    {:ok, child} = Forja.emit(:my_app, MyApp.Events.PaymentCharged,
      payload: %{id: 1},
      causation_id: parent.id,
      correlation_id: parent.correlation_id
    )

    assert_event_caused_by(:my_app, child.id, parent.id)
  end
end
```

## Telemetria

Forja inclui um logger padrao integrado que voce pode ativar:

```elixir
Forja.Telemetry.attach_default_logger(level: :info)
```

Todos os eventos de telemetria:

| Evento | Significado |
|--------|-------------|
| `[:forja, :event, :emitted]` | Evento persistido e broadcast enviado |
| `[:forja, :event, :processed]` | Handler processou com sucesso (inclui duracao) |
| `[:forja, :event, :failed]` | Handler retornou erro ou lancou excecao |
| `[:forja, :event, :dead_letter]` | Oban descartou o job |
| `[:forja, :event, :abandoned]` | Reconciliacao esgotou tentativas |
| `[:forja, :event, :reconciled]` | Reconciliacao processou evento pendente |
| `[:forja, :event, :deduplicated]` | Chave de idempotencia preveniu duplicata |
| `[:forja, :event, :validation_failed]` | Validacao de payload falhou no momento da emissao |

Para metadados detalhados de telemetria e exemplos de handlers customizados, consulte o [guia de Telemetria](https://hexdocs.pm/forja/telemetry.html).

## Configuracao

| Opcao | Padrao | Descricao |
|-------|--------|-----------|
| `:name` | *obrigatorio* | Identificador atom para a instancia Forja |
| `:repo` | *obrigatorio* | Modulo Ecto.Repo |
| `:pubsub` | *obrigatorio* | Modulo Phoenix.PubSub |
| `:oban_name` | `Oban` | Nome da instancia Oban |
| `:default_queue` | `:events` | Fila Oban padrao (resolve para `:forja_events`) |
| `:event_topic_prefix` | `"forja"` | Prefixo do topico PubSub |
| `:handlers` | `[]` | Lista de modulos `Forja.Handler` |
| `:dead_letter` | `nil` | Modulo implementando `Forja.DeadLetter` |
| `:reconciliation` | veja abaixo | Configuracoes de reconciliacao |

### Padroes de reconciliacao

```elixir
reconciliation: [
  enabled: true,
  interval_minutes: 60,
  threshold_minutes: 15,
  max_retries: 3
]
```

## Guias

Para documentacao aprofundada alem deste README:

- [Getting Started](https://hexdocs.pm/forja/getting-started.html) -- Passo a passo de configuracao
- [Architecture](https://hexdocs.pm/forja/architecture.html) -- Ciclo de vida do evento, idempotencia e supervisao
- [Event Schemas](https://hexdocs.pm/forja/event-schemas.html) -- Contratos tipados, versionamento e upcasting
- [Error Handling](https://hexdocs.pm/forja/error-handling.html) -- `on_failure/3`, integracao com Sage, dead letters
- [Telemetry](https://hexdocs.pm/forja/telemetry.html) -- Observabilidade, handlers customizados e o logger padrao
- [Testing](https://hexdocs.pm/forja/testing.html) -- Helpers de teste e padroes
- [For Agents](https://hexdocs.pm/forja/for-agents.html) -- Guia passo a passo para agentes de IA

## Licenca

MIT License. Veja [LICENSE](LICENSE) para detalhes.
