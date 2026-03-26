# Forja -- Spec Definitiva de Implementacao

**Versao:** 0.1.0
**Data:** 2026-03-25
**Status:** Aprovada para implementacao

---

## 1. Visao Geral

**Forja** e um Event Bus com dual-path processing para Elixir: eventos sao processados pelo caminho mais rapido (GenStage via PubSub) com garantia de entrega pelo Oban como fallback. A deduplicacao em tres camadas (advisory lock + `processed_at` + Oban unique) garante exactly-once processing.

A biblioteca inclui **dead letter handling** (deteccao automatica de eventos que esgotaram todas as tentativas, com callback opcional e reconciliacao periodica) e **idempotency key** (prevencao de duplicacao semantica de eventos pelo consumidor).

A biblioteca e projetada como camada fundamental de event-driven architecture, com possibilidade de evolucao futura para state machine e workflow engine sobre o mesmo barramento de eventos.

### Diagrama da Arquitetura

```
                        +-------------------+
                        |   App Code        |
                        | Forja.emit/3      |
                        | Forja.emit_multi/4|
                        +--------+----------+
                                 |
                        (1) INSERT event + Oban job
                        (dentro de Ecto.Multi + Repo.transaction)
                                 |
                  +--------------+--------------+
                  |                             |
          (2a) PubSub broadcast          (2b) Oban polls
                  |                             |
          +-------v--------+           +-------v--------+
          | GenStage        |           | Oban Worker    |
          | EventProducer   |           | ProcessEvent   |
          | -> Consumer     |           | Worker         |
          |    Supervisor   |           |                |
          +-------+--------+           +-------+--------+
                  |                             |
                  +-------------+---------------+
                                |
                   (3) advisory lock (pg_try_advisory_xact_lock)
                                |
                        +-------v--------+
                        |  Registry      |
                        |  lookup +      |
                        | Handler.handle |
                        | (exactly-once) |
                        +----------------+

Supervision Tree:
  Forja.Supervisor (strategy: :one_for_one)
    +-- Forja.ObanListener (escuta [:oban, :job, :stop] para dead letters)
    +-- Forja.EventProducer (GenStage producer)
    +-- Forja.EventConsumer (ConsumerSupervisor nativo do GenStage)
          +-- Task transiente por evento -> Forja.Processor.process/1

Notas:
- A dispatch table (:persistent_term) e construida de forma sincrona em Forja.init/1
  antes de Supervisor.init/2 -- nao requer Task separada na arvore.
- O ObanListener registra a telemetry callback com o nome registrado do processo
  (nao o PID) para evitar referencias stale apos restart do GenServer.
- notify_producers/2 usa apenas PubSub.broadcast; o EventProducer e assinante do
  topico e recebe via handle_info -- um cast direto duplicaria o evento na fila.

Oban Workers (registrados via crontab, NAO na supervision tree):
    +-- Forja.Workers.ProcessEventWorker (queue: :forja_events)
    +-- Forja.Workers.ReconciliationWorker (queue: :forja_reconciliation, cron)
```

---

## 2. mix.exs Completo

**Arquivo:** `mix.exs`

```elixir
defmodule Forja.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/forgeworksio/forja"

  def project do
    [
      app: :forja,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      name: "Forja",
      docs: docs(),
      description: "Event Bus with dual-path processing for Elixir -- PubSub latency with Oban guarantees."
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.18"},
      {:gen_stage, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Forgeworks"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Forja",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["format", "credo --strict", "dialyzer"]
    ]
  end
end
```

---

## 3. Modulos -- Implementacao Completa

### 3.1 `Forja.Config`

**Arquivo:** `lib/forja/config.ex`

```elixir
defmodule Forja.Config do
  @moduledoc """
  Configuration struct for a Forja instance.

  Stores validated configuration in `:persistent_term` for O(1) reads
  without message passing. Each Forja instance is identified by a unique `name`.

  ## Fields

    * `:name` - Atom identifying the instance (required)
    * `:repo` - Ecto.Repo module (required)
    * `:pubsub` - Phoenix.PubSub module (required)
    * `:oban_name` - Oban instance name (default: `Oban`)
    * `:consumer_pool_size` - Maximum number of concurrently processed events (default: `4`)
    * `:event_topic_prefix` - Prefix for PubSub topics (default: `"forja"`)
    * `:handlers` - List of modules implementing `Forja.Handler` (default: `[]`)
    * `:dead_letter` - Module implementing `Forja.DeadLetter` (default: `nil`, optional)
    * `:reconciliation` - Keyword list for reconciliation settings (default: see below)

  ## Reconciliation defaults

      reconciliation: [
        enabled: true,
        interval_minutes: 60,
        threshold_minutes: 15,
        max_retries: 3
      ]
  """

  @type t :: %__MODULE__{
          name: atom(),
          repo: module(),
          pubsub: module(),
          oban_name: atom(),
          consumer_pool_size: pos_integer(),
          event_topic_prefix: String.t(),
          handlers: [module()],
          dead_letter: module() | nil,
          reconciliation: keyword()
        }

  @enforce_keys [:name, :repo, :pubsub]
  defstruct [
    :name,
    :repo,
    :pubsub,
    oban_name: Oban,
    consumer_pool_size: 4,
    event_topic_prefix: "forja",
    handlers: [],
    dead_letter: nil,
    reconciliation: [
      enabled: true,
      interval_minutes: 60,
      threshold_minutes: 15,
      max_retries: 3
    ]
  ]

  @doc """
  Creates a new `Config` struct from a keyword list.

  Validates that the required fields (`:name`, `:repo`, `:pubsub`) are present.
  Raises `ArgumentError` if any required field is missing.

  ## Examples

      iex> Forja.Config.new(name: :my_app, repo: MyApp.Repo, pubsub: MyApp.PubSub)
      %Forja.Config{name: :my_app, repo: MyApp.Repo, pubsub: MyApp.PubSub, ...}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    validate_required!(opts, [:name, :repo, :pubsub])
    struct!(__MODULE__, opts)
  end

  @doc """
  Stores the configuration in `:persistent_term` indexed by the `name` field.

  The key used is `{Forja.Config, name}`.
  """
  @spec store(t()) :: :ok
  def store(%__MODULE__{name: name} = config) do
    :persistent_term.put({__MODULE__, name}, config)
  end

  @doc """
  Retrieves the configuration stored in `:persistent_term` by `name`.

  Raises `ArgumentError` if the configuration is not found.
  """
  @spec get(atom()) :: t()
  def get(name) when is_atom(name) do
    case :persistent_term.get({__MODULE__, name}, :not_found) do
      :not_found ->
        raise ArgumentError,
              "Forja instance #{inspect(name)} not found. Ensure Forja is started in your supervision tree."

      config ->
        config
    end
  end

  defp validate_required!(opts, keys) do
    Enum.each(keys, fn key ->
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError,
              "Missing required config key #{inspect(key)} for Forja. " <>
                "Required keys: #{inspect(keys)}"
      end
    end)
  end
end
```

**Arquivo de teste:** `test/forja/config_test.exs`

```elixir
defmodule Forja.ConfigTest do
  use ExUnit.Case, async: true

  alias Forja.Config

  describe "new/1" do
    test "creates config with required fields" do
      config = Config.new(name: :test_app, repo: MyApp.Repo, pubsub: MyApp.PubSub)

      assert config.name == :test_app
      assert config.repo == MyApp.Repo
      assert config.pubsub == MyApp.PubSub
    end

    test "applies default values" do
      config = Config.new(name: :test_app, repo: MyApp.Repo, pubsub: MyApp.PubSub)

      assert config.oban_name == Oban
      assert config.consumer_pool_size == 4
      assert config.event_topic_prefix == "forja"
      assert config.handlers == []
      assert config.dead_letter == nil
      assert config.reconciliation[:enabled] == true
      assert config.reconciliation[:interval_minutes] == 60
      assert config.reconciliation[:threshold_minutes] == 15
      assert config.reconciliation[:max_retries] == 3
    end

    test "allows overriding defaults" do
      config =
        Config.new(
          name: :test_app,
          repo: MyApp.Repo,
          pubsub: MyApp.PubSub,
          oban_name: MyApp.Oban,
          consumer_pool_size: 8,
          event_topic_prefix: "billing",
          handlers: [FakeHandler],
          dead_letter: FakeDeadLetter,
          reconciliation: [enabled: false, interval_minutes: 30, threshold_minutes: 10, max_retries: 5]
        )

      assert config.oban_name == MyApp.Oban
      assert config.consumer_pool_size == 8
      assert config.event_topic_prefix == "billing"
      assert config.handlers == [FakeHandler]
      assert config.dead_letter == FakeDeadLetter
      assert config.reconciliation[:enabled] == false
      assert config.reconciliation[:max_retries] == 5
    end

    test "raises on missing required field :name" do
      assert_raise ArgumentError, ~r/Missing required config key :name/, fn ->
        Config.new(repo: MyApp.Repo, pubsub: MyApp.PubSub)
      end
    end

    test "raises on missing required field :repo" do
      assert_raise ArgumentError, ~r/Missing required config key :repo/, fn ->
        Config.new(name: :test_app, pubsub: MyApp.PubSub)
      end
    end

    test "raises on missing required field :pubsub" do
      assert_raise ArgumentError, ~r/Missing required config key :pubsub/, fn ->
        Config.new(name: :test_app, repo: MyApp.Repo)
      end
    end
  end

  describe "store/1 and get/1" do
    test "stores and retrieves config by name" do
      config = Config.new(name: :store_test, repo: MyApp.Repo, pubsub: MyApp.PubSub)
      Config.store(config)

      retrieved = Config.get(:store_test)
      assert retrieved == config
    end

    test "raises when config not found" do
      assert_raise ArgumentError, ~r/Forja instance :nonexistent not found/, fn ->
        Config.get(:nonexistent)
      end
    end
  end
end
```

---

### 3.2 `Forja.Event`

**Arquivo:** `lib/forja/event.ex`

```elixir
defmodule Forja.Event do
  @moduledoc """
  Ecto schema for events persisted by Forja.

  Each event has a type (string), a flexible payload (map), optional metadata,
  and a `processed_at` field indicating when the event was successfully processed.
  The `source` field identifies the origin of the event.

  ## Fields

    * `:id` - Auto-generated UUID (binary_id)
    * `:type` - Event type as a string (e.g., `"payment:received"`)
    * `:payload` - Free-form map with event data
    * `:meta` - Free-form map with metadata (correlation_id, trace_id, etc.)
    * `:source` - String identifying the event origin
    * `:processed_at` - Timestamp of when the event was processed (nil = pending)
    * `:idempotency_key` - Optional key to prevent semantic duplication of events
    * `:reconciliation_attempts` - Number of reconciliation attempts (default: 0)
    * `:inserted_at` - Creation timestamp
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          type: String.t() | nil,
          payload: map(),
          meta: map(),
          source: String.t() | nil,
          processed_at: DateTime.t() | nil,
          idempotency_key: String.t() | nil,
          reconciliation_attempts: non_neg_integer(),
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "forja_events" do
    field :type, :string
    field :payload, :map, default: %{}
    field :meta, :map, default: %{}
    field :source, :string
    field :processed_at, :utc_datetime_usec
    field :idempotency_key, :string
    field :reconciliation_attempts, :integer, default: 0

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Creates a changeset for inserting a new event.

  Validates that the `:type` field is present and non-empty.
  Accepts an optional `:idempotency_key` for deduplication.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = event, attrs) do
    event
    |> cast(attrs, [:type, :payload, :meta, :source, :idempotency_key])
    |> validate_required([:type])
    |> validate_length(:type, min: 1, max: 255)
    |> unique_constraint(:idempotency_key, name: :forja_events_idempotency_key_index)
  end

  @doc """
  Creates a changeset to mark the event as processed.
  """
  @spec mark_processed_changeset(t()) :: Ecto.Changeset.t()
  def mark_processed_changeset(%__MODULE__{} = event) do
    change(event, processed_at: DateTime.utc_now())
  end

  @doc """
  Creates a changeset to increment the reconciliation attempts counter.
  """
  @spec increment_reconciliation_changeset(t()) :: Ecto.Changeset.t()
  def increment_reconciliation_changeset(%__MODULE__{} = event) do
    change(event, reconciliation_attempts: event.reconciliation_attempts + 1)
  end
end
```

**Arquivo de teste:** `test/forja/event_test.exs`

```elixir
defmodule Forja.EventTest do
  use ExUnit.Case, async: true

  alias Forja.Event

  describe "changeset/2" do
    test "valid changeset with required fields" do
      changeset = Event.changeset(%Event{}, %{type: "order:created"})

      assert changeset.valid?
    end

    test "valid changeset with all fields" do
      attrs = %{
        type: "order:created",
        payload: %{"order_id" => "123"},
        meta: %{"correlation_id" => "abc"},
        source: "orders_context"
      }

      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :type) == "order:created"
      assert Ecto.Changeset.get_field(changeset, :payload) == %{"order_id" => "123"}
      assert Ecto.Changeset.get_field(changeset, :meta) == %{"correlation_id" => "abc"}
      assert Ecto.Changeset.get_field(changeset, :source) == "orders_context"
    end

    test "invalid without type" do
      changeset = Event.changeset(%Event{}, %{})

      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid with empty type" do
      changeset = Event.changeset(%Event{}, %{type: ""})

      refute changeset.valid?
    end

    test "invalid with type exceeding max length" do
      long_type = String.duplicate("a", 256)
      changeset = Event.changeset(%Event{}, %{type: long_type})

      refute changeset.valid?
    end

    test "defaults payload and meta to empty maps" do
      changeset = Event.changeset(%Event{}, %{type: "test"})

      assert Ecto.Changeset.get_field(changeset, :payload) == %{}
      assert Ecto.Changeset.get_field(changeset, :meta) == %{}
    end

    test "accepts idempotency_key" do
      changeset = Event.changeset(%Event{}, %{type: "test", idempotency_key: "unique-key-123"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :idempotency_key) == "unique-key-123"
    end

    test "defaults reconciliation_attempts to zero" do
      changeset = Event.changeset(%Event{}, %{type: "test"})

      assert Ecto.Changeset.get_field(changeset, :reconciliation_attempts) == 0
    end
  end

  describe "mark_processed_changeset/1" do
    test "sets processed_at to current time" do
      event = %Event{id: Ecto.UUID.generate(), type: "test"}
      changeset = Event.mark_processed_changeset(event)

      processed_at = Ecto.Changeset.get_field(changeset, :processed_at)
      assert processed_at != nil
      assert DateTime.diff(DateTime.utc_now(), processed_at, :second) < 2
    end
  end

  describe "increment_reconciliation_changeset/1" do
    test "increments reconciliation_attempts by one" do
      event = %Event{id: Ecto.UUID.generate(), type: "test", reconciliation_attempts: 0}
      changeset = Event.increment_reconciliation_changeset(event)

      assert Ecto.Changeset.get_field(changeset, :reconciliation_attempts) == 1
    end

    test "increments from existing value" do
      event = %Event{id: Ecto.UUID.generate(), type: "test", reconciliation_attempts: 2}
      changeset = Event.increment_reconciliation_changeset(event)

      assert Ecto.Changeset.get_field(changeset, :reconciliation_attempts) == 3
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

---

### 3.3 `Forja.Handler`

**Arquivo:** `lib/forja/handler.ex`

```elixir
defmodule Forja.Handler do
  @moduledoc """
  Behaviour for Forja event handlers.

  Each handler declares which event types it processes via `event_types/0`
  and implements the processing logic in `handle_event/2`.

  Handlers are registered in the Forja instance configuration and are
  automatically dispatched when an event of the corresponding type is processed.

  ## Example

      defmodule MyApp.Events.OrderNotifier do
        @moduledoc "Sends notifications for order events."

        @behaviour Forja.Handler

        @impl Forja.Handler
        def event_types, do: ["order:created", "order:shipped"]

        @impl Forja.Handler
        def handle_event(%Forja.Event{type: "order:created"} = event, _meta) do
          MyApp.Mailer.send_confirmation(event.payload["order_id"])
          :ok
        end

        def handle_event(%Forja.Event{type: "order:shipped"} = event, _meta) do
          MyApp.Mailer.send_shipping_notification(event.payload["order_id"])
          :ok
        end
      end

  ## Failure semantics

  Handlers must be **idempotent**. If a handler fails, the remaining handlers
  for the same event are still executed. The event is marked as processed
  regardless of partial failures -- handlers that may fail should enqueue
  their own retry mechanism (e.g., an internal Oban job).
  """

  @doc """
  Returns the list of event types this handler processes.

  Return `:all` to process all event types.

  ## Examples

      def event_types, do: ["order:created", "order:shipped"]
      def event_types, do: :all
  """
  @callback event_types() :: [String.t()] | :all

  @doc """
  Processes an event.

  Receives the event and a map of contextual metadata (containing the Forja
  instance name and the processing path -- `:genstage` or `:oban`).

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback handle_event(event :: Forja.Event.t(), meta :: map()) :: :ok | {:error, term()}
end
```

**Arquivo de teste:** `test/forja/handler_test.exs`

```elixir
defmodule Forja.HandlerTest do
  use ExUnit.Case, async: true

  defmodule ValidHandler do
    @moduledoc "Valid handler for testing."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["test:event"]

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  defmodule AllEventsHandler do
    @moduledoc "Handler that processes all events."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: :all

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  test "ValidHandler implements the behaviour correctly" do
    assert ValidHandler.event_types() == ["test:event"]
    assert ValidHandler.handle_event(%Forja.Event{}, %{}) == :ok
  end

  test "AllEventsHandler returns :all for event_types" do
    assert AllEventsHandler.event_types() == :all
  end
end
```

---

### 3.3.1 `Forja.DeadLetter`

**Arquivo:** `lib/forja/dead_letter.ex`

O behaviour `DeadLetter` e **opcional**. Quando configurado via `dead_letter: MyModule` nas opcoes da Forja, o callback sera invocado quando um evento esgotar todas as tentativas de processamento (Oban discarded ou reconciliacao esgotada). Se nao configurado, apenas eventos de telemetry sao emitidos.

```elixir
defmodule Forja.DeadLetter do
  @moduledoc """
  Optional behaviour for handling dead letter events.

  When an event exhausts all processing attempts (Oban discards the job
  or the reconciliation worker exceeds its retry limit), Forja emits
  telemetry events and optionally invokes the configured `DeadLetter`
  callback module.

  Implementing this behaviour allows the consumer application to react
  to permanently failed events -- for example, by alerting operators,
  storing them in a separate table, or forwarding to an external system.

  ## Configuration

  Pass the implementing module in the Forja instance options:

      {Forja,
       name: :my_app,
       repo: MyApp.Repo,
       pubsub: MyApp.PubSub,
       dead_letter: MyApp.Events.DeadLetterHandler,
       handlers: [...]}

  ## Example

      defmodule MyApp.Events.DeadLetterHandler do
        @moduledoc "Handles dead letter events by alerting the ops team."

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
  """

  @doc """
  Called when an event has been permanently abandoned after exhausting all
  processing attempts.

  Receives the `Forja.Event` struct and the reason for abandonment.
  Must return `:ok`.
  """
  @callback handle_dead_letter(event :: Forja.Event.t(), reason :: term()) :: :ok

  @doc """
  Invokes the configured dead letter handler, if any.

  When no handler is configured (`nil`), this is a no-op.
  """
  @spec maybe_notify(module() | nil, Forja.Event.t(), term()) :: :ok
  def maybe_notify(nil, _event, _reason), do: :ok

  def maybe_notify(handler, event, reason) when is_atom(handler) do
    handler.handle_dead_letter(event, reason)
  end
end
```

**Arquivo de teste:** `test/forja/dead_letter_test.exs`

```elixir
defmodule Forja.DeadLetterTest do
  use ExUnit.Case, async: true

  alias Forja.DeadLetter
  alias Forja.Event

  defmodule TestDeadLetterHandler do
    @moduledoc "Test handler implementing DeadLetter behaviour."

    @behaviour Forja.DeadLetter

    @impl Forja.DeadLetter
    def handle_dead_letter(event, reason) do
      send(Process.whereis(:dead_letter_test), {:dead_letter, event.id, reason})
      :ok
    end
  end

  setup do
    Process.register(self(), :dead_letter_test)
    :ok
  end

  describe "maybe_notify/3" do
    test "invokes the handler when configured" do
      event = %Event{id: Ecto.UUID.generate(), type: "test:event"}

      assert :ok = DeadLetter.maybe_notify(TestDeadLetterHandler, event, :max_attempts_reached)
      assert_receive {:dead_letter, event_id, :max_attempts_reached}
      assert event_id == event.id
    end

    test "returns :ok when handler is nil" do
      event = %Event{id: Ecto.UUID.generate(), type: "test:event"}

      assert :ok = DeadLetter.maybe_notify(nil, event, :max_attempts_reached)
    end
  end
end
```

---

### 3.4 `Forja.Registry`

**Arquivo:** `lib/forja/registry.ex`

```elixir
defmodule Forja.Registry do
  @moduledoc """
  Handler registry by event type.

  Builds a dispatch table at boot from the configured handler modules
  and stores it in `:persistent_term` for O(1) lookup without message passing.

  The dispatch table is a map `%{event_type => [handler_module]}`.
  Handlers that return `:all` in `event_types/0` are stored separately
  and included in all lookups.
  """

  @type dispatch_table :: %{String.t() => [module()]}

  @doc """
  Builds the dispatch table from a list of handler modules.

  Each handler is queried via `handler.event_types()`. Handlers that
  return `:all` are separated and included in all `handlers_for/2` lookups.

  Returns `{typed_table, catch_all_handlers}`.
  """
  @spec build([module()]) :: {dispatch_table(), [module()]}
  def build(handlers) when is_list(handlers) do
    {catch_all, typed} = Enum.split_with(handlers, fn h -> h.event_types() == :all end)

    table =
      Enum.reduce(typed, %{}, fn handler, acc ->
        Enum.reduce(handler.event_types(), acc, fn type, inner ->
          Map.update(inner, type, [handler], &(&1 ++ [handler]))
        end)
      end)

    {table, catch_all}
  end

  @doc """
  Stores the dispatch table in `:persistent_term` for the `name` instance.
  """
  @spec store(atom(), dispatch_table(), [module()]) :: :ok
  def store(name, table, catch_all) do
    :persistent_term.put({__MODULE__, name, :table}, table)
    :persistent_term.put({__MODULE__, name, :catch_all}, catch_all)
  end

  @doc """
  Returns the handlers registered for an event type in the `name` instance.

  Combines type-specific handlers with `:all` handlers.
  """
  @spec handlers_for(atom(), String.t()) :: [module()]
  def handlers_for(name, event_type) when is_atom(name) and is_binary(event_type) do
    table = :persistent_term.get({__MODULE__, name, :table}, %{})
    catch_all = :persistent_term.get({__MODULE__, name, :catch_all}, [])

    Map.get(table, event_type, []) ++ catch_all
  end
end
```

**Arquivo de teste:** `test/forja/registry_test.exs`

```elixir
defmodule Forja.RegistryTest do
  use ExUnit.Case, async: true

  alias Forja.Registry

  defmodule OrderHandler do
    @moduledoc "Test handler for orders."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["order:created", "order:cancelled"]

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  defmodule NotificationHandler do
    @moduledoc "Test handler for notifications."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["order:created"]

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  defmodule AuditHandler do
    @moduledoc "Test handler that processes all events."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: :all

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  describe "build/1" do
    test "builds dispatch table from typed handlers" do
      {table, catch_all} = Registry.build([OrderHandler, NotificationHandler])

      assert catch_all == []
      assert table["order:created"] == [OrderHandler, NotificationHandler]
      assert table["order:cancelled"] == [OrderHandler]
    end

    test "separates catch-all handlers" do
      {table, catch_all} = Registry.build([OrderHandler, AuditHandler])

      assert catch_all == [AuditHandler]
      assert table["order:created"] == [OrderHandler]
      refute Map.has_key?(table, :all)
    end

    test "returns empty table for empty handlers list" do
      {table, catch_all} = Registry.build([])

      assert table == %{}
      assert catch_all == []
    end
  end

  describe "store/3 and handlers_for/2" do
    test "stores and retrieves handlers by event type" do
      {table, catch_all} = Registry.build([OrderHandler, NotificationHandler])
      Registry.store(:registry_test, table, catch_all)

      assert Registry.handlers_for(:registry_test, "order:created") == [OrderHandler, NotificationHandler]
      assert Registry.handlers_for(:registry_test, "order:cancelled") == [OrderHandler]
    end

    test "includes catch-all handlers in results" do
      {table, catch_all} = Registry.build([OrderHandler, AuditHandler])
      Registry.store(:registry_catch_all_test, table, catch_all)

      handlers = Registry.handlers_for(:registry_catch_all_test, "order:created")
      assert handlers == [OrderHandler, AuditHandler]
    end

    test "returns only catch-all handlers for unknown event types" do
      {table, catch_all} = Registry.build([OrderHandler, AuditHandler])
      Registry.store(:registry_unknown_test, table, catch_all)

      handlers = Registry.handlers_for(:registry_unknown_test, "unknown:event")
      assert handlers == [AuditHandler]
    end

    test "returns empty list when no handlers match and no catch-all" do
      {table, catch_all} = Registry.build([OrderHandler])
      Registry.store(:registry_empty_test, table, catch_all)

      assert Registry.handlers_for(:registry_empty_test, "unknown:event") == []
    end
  end
end
```

---

### 3.5 `Forja.AdvisoryLock`

**Arquivo:** `lib/forja/advisory_lock.ex`

```elixir
defmodule Forja.AdvisoryLock do
  @moduledoc """
  Wrapper for PostgreSQL's `pg_try_advisory_xact_lock`.

  Advisory locks are used to guarantee exactly-once processing:
  only one path (GenStage or Oban) processes a given event at a time.
  The lock is transaction-scoped -- automatically released on commit/rollback.

  The `with_lock/3` function attempts to acquire the lock and executes the
  provided function only if the lock is obtained. If the lock is already held
  by another transaction, returns `{:skipped, :locked}` immediately (non-blocking).
  """

  import Ecto.Query

  @doc """
  Executes `fun` inside a transaction with an advisory lock.

  The `lock_key` is converted to a 64-bit integer via `:erlang.phash2/2`.

  ## Return values

    * `{:ok, result}` - Lock acquired, function executed successfully
    * `{:skipped, :locked}` - Lock was already held by another transaction
    * `{:error, reason}` - Error in the transaction or in the function
  """
  @spec with_lock(module(), term(), (-> term())) ::
          {:ok, term()} | {:skipped, :locked} | {:error, term()}
  def with_lock(repo, lock_key, fun) when is_function(fun, 0) do
    lock_id = generate_lock_id(lock_key)

    result =
      repo.transaction(fn ->
        case acquire_lock(repo, lock_id) do
          true -> fun.()
          false -> repo.rollback(:locked)
        end
      end)

    case result do
      {:ok, value} -> {:ok, value}
      {:error, :locked} -> {:skipped, :locked}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates a non-negative integer lock ID from an arbitrary term suitable
  for use as a PostgreSQL `bigint` advisory lock key.

  Uses `:erlang.phash2/2` with a range of `2^32` (4_294_967_296), producing
  a 32-bit unsigned integer. This fits within the positive range of a signed
  64-bit `bigint` accepted by `pg_try_advisory_xact_lock` and provides a
  larger, more uniform hash space than a 31-bit range.

  Note: `:erlang.phash2/2` does not guarantee collision-freedom. For a UUID-based
  event_id the collision probability at this range is negligible in practice
  (`1 / 2^32` per pair). The `processed_at` check and Oban unique constraints
  act as additional safeguards.
  """
  @spec generate_lock_id(term()) :: non_neg_integer()
  def generate_lock_id(key) do
    :erlang.phash2(key, 4_294_967_296)
  end

  defp acquire_lock(repo, lock_id) do
    %{rows: [[result]]} =
      repo.query!("SELECT pg_try_advisory_xact_lock($1)", [lock_id])

    result
  end
end
```

**Arquivo de teste:** `test/forja/advisory_lock_test.exs`

```elixir
defmodule Forja.AdvisoryLockTest do
  use Forja.DataCase, async: false

  alias Forja.AdvisoryLock

  describe "with_lock/3" do
    test "executes function when lock is available" do
      result = AdvisoryLock.with_lock(Repo, "event-123", fn -> :processed end)

      assert {:ok, :processed} = result
    end

    test "returns skipped when lock is held by another transaction" do
      lock_key = "concurrent-event-456"
      lock_id = AdvisoryLock.generate_lock_id(lock_key)
      test_pid = self()

      task =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_id])
            send(test_pid, :lock_acquired)

            receive do
              :release -> :ok
            after
              5_000 -> :timeout
            end
          end)
        end)

      assert_receive :lock_acquired, 5_000

      result = AdvisoryLock.with_lock(Repo, lock_key, fn -> :should_not_run end)
      assert {:skipped, :locked} = result

      send(task.pid, :release)
      Task.await(task)
    end

    test "returns error when function raises" do
      result =
        AdvisoryLock.with_lock(Repo, "error-event", fn ->
          raise "boom"
        end)

      assert {:error, _} = result
    end
  end

  describe "generate_lock_id/1" do
    test "returns consistent integer for same key" do
      id1 = AdvisoryLock.generate_lock_id("event-123")
      id2 = AdvisoryLock.generate_lock_id("event-123")

      assert id1 == id2
      assert is_integer(id1)
    end

    test "returns different integers for different keys" do
      id1 = AdvisoryLock.generate_lock_id("event-123")
      id2 = AdvisoryLock.generate_lock_id("event-456")

      assert id1 != id2
    end
  end
end
```

---

### 3.6 `Forja.Telemetry`

**Arquivo:** `lib/forja/telemetry.ex`

```elixir
defmodule Forja.Telemetry do
  @moduledoc """
  Telemetry event emission for Forja.

  All events follow the `[:forja, resource, action]` convention and are
  emitted via `:telemetry.execute/3`.

  ## Emitted events

    * `[:forja, :event, :emitted]` - When an event is persisted and emitted
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, type: string, source: string}`

    * `[:forja, :event, :processed]` - When a handler processes successfully
      * Measurements: `%{duration: native_time}`
      * Metadata: `%{name: atom, type: string, handler: module, path: :genstage | :oban}`

    * `[:forja, :event, :failed]` - When a handler fails
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, type: string, handler: module, path: atom, reason: term}`

    * `[:forja, :event, :skipped]` - When the advisory lock was already held
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary, path: atom}`

    * `[:forja, :event, :dead_letter]` - When Oban discards a job (all attempts exhausted)
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary, reason: term}`

    * `[:forja, :event, :abandoned]` - When reconciliation also exhausts its retries
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary, reconciliation_attempts: integer}`

    * `[:forja, :event, :reconciled]` - When reconciliation successfully processes an event
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, event_id: binary}`

    * `[:forja, :event, :deduplicated]` - When an idempotency key prevents a duplicate emission
      * Measurements: `%{count: 1}`
      * Metadata: `%{name: atom, idempotency_key: string, existing_event_id: binary}`

    * `[:forja, :producer, :buffer_size]` - Producer buffer size
      * Measurements: `%{size: non_neg_integer}`
      * Metadata: `%{name: atom}`
  """

  @doc """
  Emits a telemetry event for event emission.
  """
  @spec emit_emitted(atom(), String.t(), String.t() | nil) :: :ok
  def emit_emitted(name, type, source) do
    :telemetry.execute(
      [:forja, :event, :emitted],
      %{count: 1},
      %{name: name, type: type, source: source}
    )
  end

  @doc """
  Emits a telemetry event for successful handler processing.
  """
  @spec emit_processed(atom(), String.t(), module(), atom(), integer()) :: :ok
  def emit_processed(name, type, handler, path, duration) do
    :telemetry.execute(
      [:forja, :event, :processed],
      %{duration: duration},
      %{name: name, type: type, handler: handler, path: path}
    )
  end

  @doc """
  Emits a telemetry event for handler failure.
  """
  @spec emit_failed(atom(), String.t(), module(), atom(), term()) :: :ok
  def emit_failed(name, type, handler, path, reason) do
    :telemetry.execute(
      [:forja, :event, :failed],
      %{count: 1},
      %{name: name, type: type, handler: handler, path: path, reason: reason}
    )
  end

  @doc """
  Emits a telemetry event for a skip due to advisory lock.
  """
  @spec emit_skipped(atom(), String.t(), atom()) :: :ok
  def emit_skipped(name, event_id, path) do
    :telemetry.execute(
      [:forja, :event, :skipped],
      %{count: 1},
      %{name: name, event_id: event_id, path: path}
    )
  end

  @doc """
  Emits a telemetry event with the producer buffer size.
  """
  @spec emit_buffer_size(atom(), non_neg_integer()) :: :ok
  def emit_buffer_size(name, size) do
    :telemetry.execute(
      [:forja, :producer, :buffer_size],
      %{size: size},
      %{name: name}
    )
  end

  @doc """
  Emits a telemetry event when Oban discards a job (dead letter).
  """
  @spec emit_dead_letter(atom(), String.t(), term()) :: :ok
  def emit_dead_letter(name, event_id, reason) do
    :telemetry.execute(
      [:forja, :event, :dead_letter],
      %{count: 1},
      %{name: name, event_id: event_id, reason: reason}
    )
  end

  @doc """
  Emits a telemetry event when reconciliation exhausts all retries (abandoned).
  """
  @spec emit_abandoned(atom(), String.t(), non_neg_integer()) :: :ok
  def emit_abandoned(name, event_id, reconciliation_attempts) do
    :telemetry.execute(
      [:forja, :event, :abandoned],
      %{count: 1},
      %{name: name, event_id: event_id, reconciliation_attempts: reconciliation_attempts}
    )
  end

  @doc """
  Emits a telemetry event when reconciliation successfully processes an event.
  """
  @spec emit_reconciled(atom(), String.t()) :: :ok
  def emit_reconciled(name, event_id) do
    :telemetry.execute(
      [:forja, :event, :reconciled],
      %{count: 1},
      %{name: name, event_id: event_id}
    )
  end

  @doc """
  Emits a telemetry event when an idempotency key prevents a duplicate emission.
  """
  @spec emit_deduplicated(atom(), String.t(), String.t()) :: :ok
  def emit_deduplicated(name, idempotency_key, existing_event_id) do
    :telemetry.execute(
      [:forja, :event, :deduplicated],
      %{count: 1},
      %{name: name, idempotency_key: idempotency_key, existing_event_id: existing_event_id}
    )
  end
end
```

**Arquivo de teste:** `test/forja/telemetry_test.exs`

```elixir
defmodule Forja.TelemetryTest do
  use ExUnit.Case, async: true

  alias Forja.Telemetry

  setup do
    ref = make_ref()
    test_pid = self()

    handler_id = "test-handler-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      [
        [:forja, :event, :emitted],
        [:forja, :event, :processed],
        [:forja, :event, :failed],
        [:forja, :event, :skipped],
        [:forja, :event, :dead_letter],
        [:forja, :event, :abandoned],
        [:forja, :event, :reconciled],
        [:forja, :event, :deduplicated],
        [:forja, :producer, :buffer_size]
      ],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "emit_emitted/3 sends telemetry event" do
    Telemetry.emit_emitted(:test, "order:created", "orders")

    assert_receive {:telemetry, [:forja, :event, :emitted], %{count: 1},
                    %{name: :test, type: "order:created", source: "orders"}}
  end

  test "emit_processed/5 sends telemetry event with duration" do
    Telemetry.emit_processed(:test, "order:created", FakeHandler, :genstage, 1_000)

    assert_receive {:telemetry, [:forja, :event, :processed], %{duration: 1_000},
                    %{name: :test, type: "order:created", handler: FakeHandler, path: :genstage}}
  end

  test "emit_failed/5 sends telemetry event with reason" do
    Telemetry.emit_failed(:test, "order:created", FakeHandler, :oban, :timeout)

    assert_receive {:telemetry, [:forja, :event, :failed], %{count: 1},
                    %{name: :test, type: "order:created", handler: FakeHandler, path: :oban, reason: :timeout}}
  end

  test "emit_skipped/3 sends telemetry event" do
    Telemetry.emit_skipped(:test, "event-uuid-123", :genstage)

    assert_receive {:telemetry, [:forja, :event, :skipped], %{count: 1},
                    %{name: :test, event_id: "event-uuid-123", path: :genstage}}
  end

  test "emit_buffer_size/2 sends telemetry event" do
    Telemetry.emit_buffer_size(:test, 42)

    assert_receive {:telemetry, [:forja, :producer, :buffer_size], %{size: 42},
                    %{name: :test}}
  end

  test "emit_dead_letter/3 sends telemetry event" do
    Telemetry.emit_dead_letter(:test, "event-uuid-dead", :max_attempts_reached)

    assert_receive {:telemetry, [:forja, :event, :dead_letter], %{count: 1},
                    %{name: :test, event_id: "event-uuid-dead", reason: :max_attempts_reached}}
  end

  test "emit_abandoned/3 sends telemetry event" do
    Telemetry.emit_abandoned(:test, "event-uuid-abandoned", 3)

    assert_receive {:telemetry, [:forja, :event, :abandoned], %{count: 1},
                    %{name: :test, event_id: "event-uuid-abandoned", reconciliation_attempts: 3}}
  end

  test "emit_reconciled/2 sends telemetry event" do
    Telemetry.emit_reconciled(:test, "event-uuid-reconciled")

    assert_receive {:telemetry, [:forja, :event, :reconciled], %{count: 1},
                    %{name: :test, event_id: "event-uuid-reconciled"}}
  end

  test "emit_deduplicated/3 sends telemetry event" do
    Telemetry.emit_deduplicated(:test, "my-idempotency-key", "existing-event-id")

    assert_receive {:telemetry, [:forja, :event, :deduplicated], %{count: 1},
                    %{name: :test, idempotency_key: "my-idempotency-key", existing_event_id: "existing-event-id"}}
  end
end
```

---

### 3.6.1 `Forja.ObanListener`

**Arquivo:** `lib/forja/oban_listener.ex`

O `ObanListener` escuta eventos de telemetry do Oban para detectar quando jobs do `ProcessEventWorker` sao descartados (discarded). Quando isso acontece, o evento correspondente entra em estado de dead letter.

```elixir
defmodule Forja.ObanListener do
  @moduledoc """
  Listens for Oban telemetry events to detect discarded `ProcessEventWorker` jobs.

  When a `ProcessEventWorker` job is discarded by Oban (all attempts exhausted),
  this module emits a `[:forja, :event, :dead_letter]` telemetry event and
  invokes the configured `Forja.DeadLetter` callback, if any.

  Started as part of the Forja supervision tree.

  ## Implementation note

  The telemetry callback looks up the listener process by its registered name
  at call time rather than capturing the PID at attach time. This is critical
  for correctness: if the GenServer restarts, a stale captured PID would point
  to a dead process. Using the registered name ensures the message always
  reaches the current live process.
  """

  use GenServer

  alias Forja.Config
  alias Forja.DeadLetter
  alias Forja.Event
  alias Forja.Telemetry

  @doc """
  Starts the ObanListener process.

  ## Options

    * `:name` - Forja instance name (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: listener_name(name))
  end

  @doc """
  Returns the registered name of the listener for a Forja instance.
  """
  @spec listener_name(atom()) :: atom()
  def listener_name(name) do
    Module.concat([Forja, ObanListener, name])
  end

  @impl GenServer
  def init(opts) do
    forja_name = Keyword.fetch!(opts, :name)
    handler_id = "forja-oban-listener-#{forja_name}"

    :telemetry.attach(
      handler_id,
      [:oban, :job, :stop],
      &__MODULE__.handle_oban_event/4,
      %{forja_name: forja_name, listener_name: listener_name(forja_name)}
    )

    {:ok, %{forja_name: forja_name, handler_id: handler_id}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @doc """
  Telemetry handler callback for Oban job stop events.

  Filters for discarded `Forja.Workers.ProcessEventWorker` jobs and sends
  a message to the `ObanListener` GenServer process for asynchronous
  dead letter processing.

  Telemetry handlers must be non-blocking. All I/O (DB lookup, dead letter
  callback) is delegated to the GenServer via `send/2` so that the Oban
  worker process is not held up.

  The listener process is resolved by its registered name at call time to
  avoid stale PID references after a GenServer restart.
  """
  @spec handle_oban_event([atom()], map(), map(), map()) :: :ok
  def handle_oban_event(
        [:oban, :job, :stop],
        _measurements,
        %{job: %Oban.Job{state: "discarded", worker: worker, args: %{"event_id" => event_id}}},
        %{forja_name: forja_name, listener_name: listener_name}
      )
      when worker == "Forja.Workers.ProcessEventWorker" do
    case Process.whereis(listener_name) do
      nil -> :ok
      pid -> send(pid, {:dead_letter_check, forja_name, event_id})
    end

    :ok
  end

  def handle_oban_event(_event_name, _measurements, _metadata, _config), do: :ok

  @impl GenServer
  def handle_info({:dead_letter_check, forja_name, event_id}, state) do
    config = Config.get(forja_name)

    case config.repo.get(Event, event_id) do
      nil ->
        :ok

      %Event{} = event ->
        Telemetry.emit_dead_letter(forja_name, event_id, :oban_discarded)
        DeadLetter.maybe_notify(config.dead_letter, event, :oban_discarded)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

**Arquivo de teste:** `test/forja/oban_listener_test.exs`

```elixir
defmodule Forja.ObanListenerTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.ObanListener
  alias Forja.Registry

  defmodule TestDeadLetterHandler do
    @moduledoc "Test dead letter handler for ObanListener."

    @behaviour Forja.DeadLetter

    @impl Forja.DeadLetter
    def handle_dead_letter(event, reason) do
      send(Process.whereis(:oban_listener_test), {:dead_letter, event.id, reason})
      :ok
    end
  end

  setup do
    Process.register(self(), :oban_listener_test)

    config =
      Config.new(
        name: :oban_listener_test,
        repo: Repo,
        pubsub: Forja.TestPubSub,
        handlers: [],
        dead_letter: TestDeadLetterHandler
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:oban_listener_test, table, catch_all)

    start_supervised!({ObanListener, name: :oban_listener_test})

    :ok
  end

  describe "dead letter detection via telemetry" do
    test "notifies dead letter handler when ProcessEventWorker is discarded" do
      event = insert_event!("oban_listener_test:event")
      listener_name = ObanListener.listener_name(:oban_listener_test)

      metadata = %{
        job: %Oban.Job{
          state: "discarded",
          worker: "Forja.Workers.ProcessEventWorker",
          args: %{"event_id" => event.id, "forja_name" => "oban_listener_test"}
        }
      }

      ObanListener.handle_oban_event(
        [:oban, :job, :stop],
        %{duration: 1_000},
        metadata,
        %{forja_name: :oban_listener_test, listener_name: listener_name}
      )

      assert_receive {:dead_letter, event_id, :oban_discarded}, 1_000
      assert event_id == event.id
    end

    test "ignores non-discarded jobs" do
      listener_name = ObanListener.listener_name(:oban_listener_test)

      metadata = %{
        job: %Oban.Job{
          state: "completed",
          worker: "Forja.Workers.ProcessEventWorker",
          args: %{"event_id" => "some-id", "forja_name" => "oban_listener_test"}
        }
      }

      ObanListener.handle_oban_event(
        [:oban, :job, :stop],
        %{duration: 1_000},
        metadata,
        %{forja_name: :oban_listener_test, listener_name: listener_name}
      )

      refute_receive {:dead_letter, _, _}
    end

    test "ignores jobs from other workers" do
      listener_name = ObanListener.listener_name(:oban_listener_test)

      metadata = %{
        job: %Oban.Job{
          state: "discarded",
          worker: "SomeOtherWorker",
          args: %{"event_id" => "some-id"}
        }
      }

      ObanListener.handle_oban_event(
        [:oban, :job, :stop],
        %{duration: 1_000},
        metadata,
        %{forja_name: :oban_listener_test, listener_name: listener_name}
      )

      refute_receive {:dead_letter, _, _}
    end
  end

  defp insert_event!(type) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Repo.insert!()
  end
end
```

---

### 3.7 `Forja.Processor`

**Arquivo:** `lib/forja/processor.ex`

```elixir
defmodule Forja.Processor do
  @moduledoc """
  Functional core of exactly-once processing.

  Orchestrates the flow:
  1. Acquires an advisory lock for the event
  2. Loads the event from the database (if necessary)
  3. Checks if it has already been processed (`processed_at`)
  4. Dispatches to handlers via Registry
  5. Marks as processed

  This module is called by both the GenStage consumer and the Oban worker.
  It has no state -- it is a pure functional module.
  """

  require Logger

  alias Forja.AdvisoryLock
  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Telemetry

  @doc """
  Processes an event identified by `event_id`.

  The `path` indicates the processing origin (`:genstage`, `:oban`,
  `:reconciliation`, or `:inline`) and is used for telemetry.

  ## Return values

    * `:ok` - Event processed successfully (or already processed)
    * `{:skipped, :locked}` - Lock was already held by another path
    * `{:error, reason}` - Error during processing
  """
  @spec process(atom(), String.t(), atom()) :: :ok | {:skipped, :locked} | {:error, term()}
  def process(name, event_id, path) do
    config = Config.get(name)
    lock_result = AdvisoryLock.with_lock(config.repo, {:forja_event, event_id}, fn ->
      do_process(config, name, event_id, path)
    end)

    case lock_result do
      {:ok, :ok} ->
        :ok

      {:ok, {:already_processed, _}} ->
        :ok

      {:skipped, :locked} ->
        Telemetry.emit_skipped(name, event_id, path)
        {:skipped, :locked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_process(config, name, event_id, path) do
    case config.repo.get(Event, event_id) do
      nil ->
        Logger.warning("Forja: event #{event_id} not found in database")
        :ok

      %Event{processed_at: processed_at} when not is_nil(processed_at) ->
        {:already_processed, event_id}

      %Event{} = event ->
        dispatch_to_handlers(config, name, event, path)
        mark_processed(config, event)
        :ok
    end
  end

  defp dispatch_to_handlers(config, name, event, path) do
    handlers = Registry.handlers_for(name, event.type)

    Enum.each(handlers, fn handler ->
      start_time = System.monotonic_time()

      try do
        meta = %{forja_name: name, path: path}

        case handler.handle_event(event, meta) do
          :ok ->
            duration = System.monotonic_time() - start_time
            Telemetry.emit_processed(name, event.type, handler, path, duration)

          {:error, reason} ->
            Logger.error(
              "Forja: handler #{inspect(handler)} returned error for event #{event.id}: #{inspect(reason)}"
            )

            Telemetry.emit_failed(name, event.type, handler, path, reason)
        end
      rescue
        exception ->
          Logger.error(
            "Forja: handler #{inspect(handler)} raised for event #{event.id}: #{Exception.message(exception)}"
          )

          Telemetry.emit_failed(name, event.type, handler, path, exception)
      end
    end)
  end

  defp mark_processed(config, event) do
    event
    |> Event.mark_processed_changeset()
    |> config.repo.update!()
  end
end
```

**Arquivo de teste:** `test/forja/processor_test.exs`

```elixir
defmodule Forja.ProcessorTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.Processor
  alias Forja.Registry

  defmodule SuccessHandler do
    @moduledoc "Handler that always returns :ok."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["test:success"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:processor_test), {:handled, event.id})
      :ok
    end
  end

  defmodule ErrorHandler do
    @moduledoc "Handler that always returns an error."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["test:error"]

    @impl Forja.Handler
    def handle_event(_event, _meta) do
      {:error, :handler_failed}
    end
  end

  defmodule RaisingHandler do
    @moduledoc "Handler that always raises an exception."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["test:raise"]

    @impl Forja.Handler
    def handle_event(_event, _meta) do
      raise "boom"
    end
  end

  setup do
    Process.register(self(), :processor_test)

    config =
      Config.new(
        name: :processor_test,
        repo: Repo,
        pubsub: Forja.TestPubSub,
        handlers: [SuccessHandler, ErrorHandler, RaisingHandler]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:processor_test, table, catch_all)

    :ok
  end

  describe "process/3" do
    test "processes event and marks as processed" do
      event = insert_event!("test:success")

      assert :ok = Processor.process(:processor_test, event.id, :genstage)
      assert_receive {:handled, event_id}
      assert event_id == event.id

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "skips already processed events" do
      event = insert_event!("test:success", processed_at: DateTime.utc_now())

      assert :ok = Processor.process(:processor_test, event.id, :genstage)
      refute_receive {:handled, _}
    end

    test "returns ok for non-existent events" do
      assert :ok = Processor.process(:processor_test, Ecto.UUID.generate(), :genstage)
    end

    test "marks event as processed even when handler returns error" do
      event = insert_event!("test:error")

      assert :ok = Processor.process(:processor_test, event.id, :oban)

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "marks event as processed even when handler raises" do
      event = insert_event!("test:raise")

      assert :ok = Processor.process(:processor_test, event.id, :oban)

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end
  end

  defp insert_event!(type, attrs \\ []) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end
```

---

### 3.8 `Forja.EventProducer`

**Arquivo:** `lib/forja/event_producer.ex`

```elixir
defmodule Forja.EventProducer do
  @moduledoc """
  GenStage Producer that receives notifications of new events via PubSub
  and buffers them for consumption by `Forja.EventConsumer`.

  The Producer subscribes to the PubSub topic `"{prefix}:events"` and
  forwards event IDs to consumers via the native GenStage buffer.

  The native GenStage buffer (configured via `buffer_size`, default 10_000)
  handles back-pressure automatically: when consumers have no pending demand,
  events accumulate in the buffer. When the buffer is full, GenStage drops
  the oldest events. Dropped events will be processed by the Oban path --
  this is a feature of the dual-path design, not a bug.

  The producer does **not** maintain a secondary internal queue. Demand
  accumulation and event dispatching are delegated entirely to the GenStage
  runtime, which is the correct approach for producers that emit events
  reactively via `handle_info` or `handle_cast`.
  """

  use GenStage

  @doc """
  Starts the EventProducer.

  ## Options

    * `:name` - Forja instance name (required)
    * `:pubsub` - PubSub module (required)
    * `:event_topic_prefix` - Topic prefix (default: `"forja"`)
    * `:buffer_size` - Maximum native GenStage buffer size (default: `10_000`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenStage.start_link(__MODULE__, opts, name: producer_name(name))
  end

  @doc """
  Adds an event ID to the producer buffer for processing via GenStage.

  In production, the producer is notified via the PubSub topic it subscribes to
  during `init/1`. This function is exposed for testing scenarios where a direct
  cast is more convenient than broadcasting through PubSub.

  Callers should not use both `notify/2` and a PubSub broadcast for the same
  event, as this would enqueue the event twice.
  """
  @spec notify(atom(), String.t()) :: :ok
  def notify(name, event_id) do
    GenStage.cast(producer_name(name), {:notify, event_id})
  end

  @doc """
  Returns the registered name of the producer for a Forja instance.
  """
  @spec producer_name(atom()) :: atom()
  def producer_name(name) do
    Module.concat([Forja, Producer, name])
  end

  @impl GenStage
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    pubsub = Keyword.fetch!(opts, :pubsub)
    prefix = Keyword.get(opts, :event_topic_prefix, "forja")
    buffer_size = Keyword.get(opts, :buffer_size, 10_000)

    topic = "#{prefix}:events"
    Phoenix.PubSub.subscribe(pubsub, topic)

    {:producer, %{name: name}, buffer_size: buffer_size}
  end

  @impl GenStage
  def handle_cast({:notify, event_id}, state) do
    {:noreply, [event_id], state}
  end

  @impl GenStage
  def handle_info({:forja_event, event_id}, state) do
    {:noreply, [event_id], state}
  end

  @impl GenStage
  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end
end
```

**Arquivo de teste:** `test/forja/event_producer_test.exs`

```elixir
defmodule Forja.EventProducerTest do
  use ExUnit.Case, async: false

  alias Forja.EventProducer

  setup do
    start_supervised!({Phoenix.PubSub, name: Forja.ProducerTestPubSub})

    opts = [
      name: :producer_test,
      pubsub: Forja.ProducerTestPubSub,
      event_topic_prefix: "test_forja"
    ]

    start_supervised!({EventProducer, opts})

    :ok
  end

  test "producer_name/1 returns a deterministic name" do
    assert EventProducer.producer_name(:my_app) == Forja.Producer.my_app
  end

  test "notify/2 buffers event IDs for consumption" do
    EventProducer.notify(:producer_test, "event-1")
    EventProducer.notify(:producer_test, "event-2")

    {:ok, consumer_pid} =
      GenStage.start_link(Forja.TestConsumer, %{test_pid: self(), subscribe_to: EventProducer.producer_name(:producer_test)})

    assert_receive {:consumed, "event-1"}, 1_000
    assert_receive {:consumed, "event-2"}, 1_000

    GenStage.stop(consumer_pid)
  end

  test "handles PubSub messages" do
    {:ok, consumer_pid} =
      GenStage.start_link(Forja.TestConsumer, %{test_pid: self(), subscribe_to: EventProducer.producer_name(:producer_test)})

    Phoenix.PubSub.broadcast(
      Forja.ProducerTestPubSub,
      "test_forja:events",
      {:forja_event, "pubsub-event-1"}
    )

    assert_receive {:consumed, "pubsub-event-1"}, 1_000

    GenStage.stop(consumer_pid)
  end
end
```

**Arquivo de suporte para testes:** `test/support/test_consumer.ex`

```elixir
defmodule Forja.TestConsumer do
  @moduledoc """
  GenStage test consumer that sends messages to the test process.
  """

  use GenStage

  @impl GenStage
  def init(%{test_pid: test_pid, subscribe_to: producer}) do
    {:consumer, %{test_pid: test_pid}, subscribe_to: [{producer, max_demand: 1}]}
  end

  @impl GenStage
  def handle_events(events, _from, state) do
    Enum.each(events, fn event_id ->
      send(state.test_pid, {:consumed, event_id})
    end)

    {:noreply, [], state}
  end
end
```

---

### 3.9 `Forja.EventConsumer`

**Arquivo:** `lib/forja/event_consumer.ex`

```elixir
defmodule Forja.EventConsumer do
  @moduledoc """
  Native GenStage ConsumerSupervisor that spawns one Task per event.

  Each event received from `Forja.EventProducer` is processed in an isolated
  transient Task. If the Task fails, the supervisor handles the restart in
  isolation without affecting other events.

  The `max_demand` controls the maximum processing concurrency.
  """

  use ConsumerSupervisor

  @doc """
  Starts the EventConsumer.

  ## Options

    * `:name` - Forja instance name (required)
    * `:producer` - Registered name of the producer (required)
    * `:max_demand` - Maximum concurrency (default: `4`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    ConsumerSupervisor.start_link(__MODULE__, opts, name: consumer_name(name))
  end

  @doc """
  Returns the registered name of the consumer supervisor for a Forja instance.
  """
  @spec consumer_name(atom()) :: atom()
  def consumer_name(name) do
    Module.concat([Forja, Consumer, name])
  end

  @impl ConsumerSupervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    producer = Keyword.fetch!(opts, :producer)
    max_demand = Keyword.get(opts, :max_demand, 4)

    children = [
      %{
        id: Forja.EventWorker,
        start: {Forja.EventWorker, :start_link, [name]},
        restart: :transient
      }
    ]

    consumer_opts = [
      strategy: :one_for_one,
      subscribe_to: [{producer, max_demand: max_demand, min_demand: 0}]
    ]

    ConsumerSupervisor.init(children, consumer_opts)
  end
end
```

**Arquivo:** `lib/forja/event_worker.ex`

```elixir
defmodule Forja.EventWorker do
  @moduledoc """
  Transient Task that processes a single event via `Forja.Processor`.

  Spawned by `Forja.EventConsumer` (ConsumerSupervisor) for each event
  received from the producer. Dies after processing, releasing demand
  for the next event.
  """

  @doc """
  Starts a Task that processes the event identified by `event_id`.
  """
  @spec start_link(atom(), String.t()) :: {:ok, pid()}
  def start_link(name, event_id) do
    Task.start_link(fn ->
      Forja.Processor.process(name, event_id, :genstage)
    end)
  end
end
```

**Arquivo de teste:** `test/forja/event_consumer_test.exs`

```elixir
defmodule Forja.EventConsumerTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.EventConsumer
  alias Forja.EventProducer
  alias Forja.Registry

  defmodule TestHandler do
    @moduledoc "Test handler that notifies the test process."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["consumer_test:event"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:consumer_test), {:handled, event.id})
      :ok
    end
  end

  setup do
    Process.register(self(), :consumer_test)

    start_supervised!({Phoenix.PubSub, name: Forja.ConsumerTestPubSub})

    config =
      Config.new(
        name: :consumer_test,
        repo: Repo,
        pubsub: Forja.ConsumerTestPubSub,
        handlers: [TestHandler]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:consumer_test, table, catch_all)

    producer_opts = [
      name: :consumer_test,
      pubsub: Forja.ConsumerTestPubSub,
      event_topic_prefix: "consumer_test"
    ]

    start_supervised!({EventProducer, producer_opts})

    consumer_opts = [
      name: :consumer_test,
      producer: EventProducer.producer_name(:consumer_test),
      max_demand: 2
    ]

    start_supervised!({EventConsumer, consumer_opts})

    :ok
  end

  test "processes events dispatched through the GenStage pipeline" do
    test_pid = self()
    handler_id = "consumer-test-telemetry-#{inspect(self())}"

    :telemetry.attach(
      handler_id,
      [:forja, :event, :processed],
      fn _event, _measurements, _metadata, _ -> send(test_pid, :telemetry_processed) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    event = insert_event!("consumer_test:event")

    EventProducer.notify(:consumer_test, event.id)

    assert_receive {:handled, event_id}, 5_000
    assert event_id == event.id

    assert_receive :telemetry_processed, 5_000

    reloaded = Repo.get!(Event, event.id)
    assert reloaded.processed_at != nil
  end

  test "processes multiple events concurrently" do
    event1 = insert_event!("consumer_test:event")
    event2 = insert_event!("consumer_test:event")

    EventProducer.notify(:consumer_test, event1.id)
    EventProducer.notify(:consumer_test, event2.id)

    assert_receive {:handled, _}, 5_000
    assert_receive {:handled, _}, 5_000
  end

  defp insert_event!(type) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Repo.insert!()
  end
end
```

---

### 3.10 `Forja.Workers.ProcessEventWorker`

**Arquivo:** `lib/forja/workers/process_event_worker.ex`

```elixir
defmodule Forja.Workers.ProcessEventWorker do
  @moduledoc """
  Oban Worker for the guaranteed delivery path.

  Processes events via `Forja.Processor` with the same logic as the GenStage path.
  If GenStage already processed the event, the advisory lock or the `processed_at`
  check guarantee there is no reprocessing.

  ## Configuration

    * Queue: `:forja_events`
    * Unique: by `event_id`, period of 300 seconds
    * Max attempts: 3
  """

  use Oban.Worker,
    queue: :forja_events,
    unique: [keys: [:event_id], period: 300],
    max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id, "forja_name" => forja_name}}) do
    name = String.to_existing_atom(forja_name)

    case Forja.Processor.process(name, event_id, :oban) do
      :ok -> :ok
      {:skipped, :locked} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:cancel, "Unknown Forja instance: #{forja_name}"}
  end
end
```

**Arquivo de teste:** `test/forja/workers/process_event_worker_test.exs`

```elixir
defmodule Forja.Workers.ProcessEventWorkerTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Workers.ProcessEventWorker

  defmodule WorkerTestHandler do
    @moduledoc "Test handler for the Oban worker."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["worker_test:event"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:worker_test), {:handled, event.id})
      :ok
    end
  end

  setup do
    Process.register(self(), :worker_test)

    config =
      Config.new(
        name: :worker_test,
        repo: Repo,
        pubsub: Forja.TestPubSub,
        handlers: [WorkerTestHandler]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:worker_test, table, catch_all)

    :ok
  end

  describe "perform/1" do
    test "processes event via Processor" do
      event = insert_event!("worker_test:event")

      job = %Oban.Job{
        args: %{"event_id" => event.id, "forja_name" => "worker_test"}
      }

      assert :ok = ProcessEventWorker.perform(job)
      assert_receive {:handled, event_id}
      assert event_id == event.id

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "returns ok for already processed events" do
      event = insert_event!("worker_test:event", processed_at: DateTime.utc_now())

      job = %Oban.Job{
        args: %{"event_id" => event.id, "forja_name" => "worker_test"}
      }

      assert :ok = ProcessEventWorker.perform(job)
      refute_receive {:handled, _}
    end

    test "cancels job when forja_name is not a known atom" do
      job = %Oban.Job{
        args: %{"event_id" => Ecto.UUID.generate(), "forja_name" => "nonexistent_forja_instance_xyz"}
      }

      assert {:cancel, _reason} = ProcessEventWorker.perform(job)
    end
  end

  defp insert_event!(type, attrs \\ []) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end
```

---

### 3.10.1 `Forja.Workers.ReconciliationWorker`

**Arquivo:** `lib/forja/workers/reconciliation_worker.ex`

O `ReconciliationWorker` e um Oban cron worker que busca eventos pendentes que excederam o threshold de tempo e nao foram processados. Para cada evento encontrado, tenta processamento via `Forja.Processor`. Se o evento tambem excede o maximo de tentativas de reconciliacao, entra em estado de abandoned (dead letter final).

O worker e registrado via Oban plugins/crontab na configuracao do Oban, NAO como child separado da supervision tree.

```elixir
defmodule Forja.Workers.ReconciliationWorker do
  @moduledoc """
  Oban cron worker for reconciling unprocessed events.

  Periodically scans the `forja_events` table for events that remain
  unprocessed beyond a configurable threshold. For each stale event:

  1. Attempts processing via `Forja.Processor.process/3` with the
     `:reconciliation` path
  2. On success: the event is processed normally and
     `[:forja, :event, :reconciled]` telemetry is emitted
  3. On failure: increments `reconciliation_attempts` on the event
  4. When `reconciliation_attempts >= max_retries`: emits
     `[:forja, :event, :abandoned]` telemetry and invokes the
     configured `Forja.DeadLetter` callback

  ## Configuration

  Configured via the `:reconciliation` key in the Forja instance options:

      reconciliation: [
        enabled: true,
        interval_minutes: 60,
        threshold_minutes: 15,
        max_retries: 3
      ]

  ## Oban crontab setup

  Register this worker in the Oban configuration:

      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10, forja_events: 5, forja_reconciliation: 1],
        plugins: [
          {Oban.Plugins.Cron, crontab: [
            {"0 * * * *", Forja.Workers.ReconciliationWorker,
             args: %{forja_name: "my_app"}}
          ]}
        ]
  """

  use Oban.Worker,
    queue: :forja_reconciliation,
    unique: [period: 3600, keys: [:forja_name]],
    max_attempts: 1

  import Ecto.Query

  alias Forja.Config
  alias Forja.DeadLetter
  alias Forja.Event
  alias Forja.Telemetry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forja_name" => forja_name_str}}) do
    forja_name = String.to_existing_atom(forja_name_str)
    config = Config.get(forja_name)
    reconciliation = config.reconciliation

    if Keyword.get(reconciliation, :enabled, true) do
      threshold_minutes = Keyword.get(reconciliation, :threshold_minutes, 15)
      max_retries = Keyword.get(reconciliation, :max_retries, 3)
      cutoff = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

      stale_events =
        config.repo.all(
          from(e in Event,
            where: is_nil(e.processed_at),
            where: e.inserted_at < ^cutoff,
            where: e.reconciliation_attempts < ^max_retries,
            order_by: [asc: e.inserted_at]
          )
        )

      Enum.each(stale_events, fn event ->
        reconcile_event(config, forja_name, event, max_retries)
      end)

      :ok
    else
      {:ok, :disabled}
    end
  rescue
    ArgumentError -> {:cancel, "Unknown Forja instance: #{forja_name_str}"}
  end

  defp reconcile_event(config, forja_name, event, max_retries) do
    case Forja.Processor.process(forja_name, event.id, :reconciliation) do
      :ok ->
        Telemetry.emit_reconciled(forja_name, event.id)

      {:skipped, :locked} ->
        :ok

      {:error, _reason} ->
        updated_event =
          event
          |> Event.increment_reconciliation_changeset()
          |> config.repo.update!()

        if updated_event.reconciliation_attempts >= max_retries do
          Telemetry.emit_abandoned(forja_name, event.id, updated_event.reconciliation_attempts)
          DeadLetter.maybe_notify(config.dead_letter, updated_event, :reconciliation_exhausted)
        end
    end
  end
end
```

**Arquivo de teste:** `test/forja/workers/reconciliation_worker_test.exs`

```elixir
defmodule Forja.Workers.ReconciliationWorkerTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Workers.ReconciliationWorker

  defmodule ReconciliationTestHandler do
    @moduledoc "Test handler for reconciliation."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["reconciliation_test:event"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:reconciliation_test), {:handled, event.id})
      :ok
    end
  end

  defmodule FailingHandler do
    @moduledoc "Handler that always fails for reconciliation tests."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["reconciliation_test:failing"]

    @impl Forja.Handler
    def handle_event(_event, _meta) do
      {:error, :always_fails}
    end
  end

  defmodule TestDeadLetterHandler do
    @moduledoc "Test dead letter handler for reconciliation."

    @behaviour Forja.DeadLetter

    @impl Forja.DeadLetter
    def handle_dead_letter(event, reason) do
      send(Process.whereis(:reconciliation_test), {:dead_letter, event.id, reason})
      :ok
    end
  end

  setup do
    Process.register(self(), :reconciliation_test)

    config =
      Config.new(
        name: :reconciliation_test,
        repo: Repo,
        pubsub: Forja.TestPubSub,
        handlers: [ReconciliationTestHandler, FailingHandler],
        dead_letter: TestDeadLetterHandler,
        reconciliation: [
          enabled: true,
          interval_minutes: 60,
          threshold_minutes: 0,
          max_retries: 2
        ]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:reconciliation_test, table, catch_all)

    :ok
  end

  describe "perform/1" do
    test "processes stale unprocessed events" do
      event = insert_stale_event!("reconciliation_test:event")

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      assert_receive {:handled, event_id}
      assert event_id == event.id

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "ignores recently inserted events within threshold" do
      config =
        Config.new(
          name: :reconciliation_threshold_test,
          repo: Repo,
          pubsub: Forja.TestPubSub,
          handlers: [ReconciliationTestHandler],
          reconciliation: [enabled: true, interval_minutes: 60, threshold_minutes: 60, max_retries: 3]
        )

      Config.store(config)

      {table, catch_all} = Registry.build(config.handlers)
      Registry.store(:reconciliation_threshold_test, table, catch_all)

      _event = insert_event!("reconciliation_test:event")

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_threshold_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      refute_receive {:handled, _}
    end

    test "increments reconciliation_attempts on failure" do
      event = insert_stale_event!("reconciliation_test:failing")

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.reconciliation_attempts == 1
      assert reloaded.processed_at == nil
    end

    test "triggers dead letter when max retries exhausted" do
      event = insert_stale_event!("reconciliation_test:failing", reconciliation_attempts: 1)

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      assert_receive {:dead_letter, event_id, :reconciliation_exhausted}
      assert event_id == event.id

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.reconciliation_attempts == 2
    end

    test "returns disabled when reconciliation is disabled" do
      config =
        Config.new(
          name: :reconciliation_disabled_test,
          repo: Repo,
          pubsub: Forja.TestPubSub,
          handlers: [],
          reconciliation: [enabled: false]
        )

      Config.store(config)

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_disabled_test"}}
      assert {:ok, :disabled} = ReconciliationWorker.perform(job)
    end

    test "skips events that already reached max retries" do
      _event = insert_stale_event!("reconciliation_test:failing", reconciliation_attempts: 2)

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      refute_receive {:dead_letter, _, _}
    end

    test "cancels job when forja_name is not a known atom" do
      job = %Oban.Job{args: %{"forja_name" => "nonexistent_forja_instance_xyz"}}

      assert {:cancel, _reason} = ReconciliationWorker.perform(job)
    end
  end

  defp insert_event!(type) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Repo.insert!()
  end

  defp insert_stale_event!(type, attrs \\ []) do
    stale_time = DateTime.add(DateTime.utc_now(), -3600, :second)

    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Ecto.Changeset.change([{:inserted_at, stale_time} | attrs])
    |> Repo.insert!()
  end
end
```

---

### 3.11 `Forja` (Modulo Principal)

**Arquivo:** `lib/forja.ex`

```elixir
defmodule Forja do
  @moduledoc """
  Event Bus with dual-path processing for Elixir.

  Forja combines PubSub/GenStage latency with Oban delivery guarantees.
  Events are processed by the fastest path, with three-layer deduplication
  (advisory lock + `processed_at` + Oban unique).

  ## Usage

      children = [
        {Forja,
         name: :my_app,
         repo: MyApp.Repo,
         pubsub: MyApp.PubSub,
         handlers: [MyApp.Events.OrderHandler],
         dead_letter: MyApp.Events.DeadLetterHandler,
         reconciliation: [enabled: true, interval_minutes: 60, threshold_minutes: 15, max_retries: 3]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Emitting events

      Forja.emit(:my_app, "order:created",
        payload: %{"order_id" => order.id},
        source: "orders"
      )

  ## Idempotent emission

      Forja.emit(:my_app, "order:created",
        payload: %{"order_id" => order.id},
        source: "orders",
        idempotency_key: "order-created-\#{order.id}"
      )

  ## Transactional emission

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:order, order_changeset)
      |> Forja.emit_multi(:my_app, "order:created",
        payload_fn: fn %{order: order} -> %{"order_id" => order.id} end,
        source: "orders"
      )
      |> Repo.transaction()
  """

  use Supervisor

  import Ecto.Query

  alias Forja.Config
  alias Forja.Event
  alias Forja.EventConsumer
  alias Forja.EventProducer
  alias Forja.ObanListener
  alias Forja.Registry
  alias Forja.Telemetry

  @doc """
  Starts the Forja instance as part of a supervision tree.

  ## Options

    * `:name` - Atom identifier for the instance (required)
    * `:repo` - Ecto.Repo module (required)
    * `:pubsub` - Phoenix.PubSub module (required)
    * `:oban_name` - Oban instance name (default: `Oban`)
    * `:consumer_pool_size` - Maximum processing concurrency (default: `4`)
    * `:event_topic_prefix` - Prefix for PubSub topics (default: `"forja"`)
    * `:handlers` - List of `Forja.Handler` modules (default: `[]`)
    * `:dead_letter` - Module implementing `Forja.DeadLetter` (default: `nil`)
    * `:reconciliation` - Keyword list for reconciliation settings (default: see `Forja.Config`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    config = Config.new(opts)
    Supervisor.start_link(__MODULE__, config, name: supervisor_name(config.name))
  end

  @doc """
  Emits an event atomically.

  Inside an Ecto.Multi transaction:
  1. Inserts the event into the `forja_events` table
  2. Inserts the Oban `ProcessEventWorker` job

  After the commit:
  3. Broadcasts via PubSub
  4. Notifies the EventProducer

  ## Options

    * `:payload` - Map with event data (default: `%{}`)
    * `:meta` - Map with metadata (default: `%{}`)
    * `:source` - String identifying the origin (default: `nil`)
    * `:idempotency_key` - Optional string key for deduplication (default: `nil`)

  ## Idempotency

  When `:idempotency_key` is provided, the function checks for an existing event
  with the same key before inserting:

    * If found with `processed_at` set: returns `{:ok, :already_processed}`
    * If found with `processed_at: nil`: re-enqueues the Oban job and returns
      `{:ok, :retrying, existing_event_id}`
    * If not found: emits normally
  """
  @spec emit(atom(), String.t(), keyword()) ::
          {:ok, Event.t()}
          | {:ok, :already_processed}
          | {:ok, :retrying, String.t()}
          | {:error, Ecto.Changeset.t()}
  def emit(name, type, opts \\ []) do
    config = Config.get(name)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    attrs =
      %{
        type: type,
        payload: Keyword.get(opts, :payload, %{}),
        meta: Keyword.get(opts, :meta, %{}),
        source: Keyword.get(opts, :source)
      }
      |> maybe_put_idempotency_key(idempotency_key)

    case check_idempotency(config, idempotency_key) do
      :proceed ->
        do_emit(config, name, attrs)

      {:already_processed, event} ->
        Telemetry.emit_deduplicated(name, idempotency_key, event.id)
        {:ok, :already_processed}

      {:retrying, event} ->
        Telemetry.emit_deduplicated(name, idempotency_key, event.id)
        reenqueue_event(config, name, event)
        {:ok, :retrying, event.id}
    end
  end

  defp check_idempotency(_config, nil), do: :proceed

  defp check_idempotency(config, idempotency_key) do
    case config.repo.one(
           from(e in Event, where: e.idempotency_key == ^idempotency_key, limit: 1)
         ) do
      nil ->
        :proceed

      %Event{processed_at: processed_at} = event when not is_nil(processed_at) ->
        {:already_processed, event}

      %Event{} = event ->
        {:retrying, event}
    end
  end

  defp do_emit(config, name, attrs) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:event, fn _changes ->
        Event.changeset(%Event{}, attrs)
      end)
      |> Ecto.Multi.run(:oban_job, fn _repo, %{event: event} ->
        job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
        changeset = Forja.Workers.ProcessEventWorker.new(job_args)
        Oban.insert(config.oban_name, changeset)
      end)

    case config.repo.transaction(multi) do
      {:ok, %{event: event}} ->
        after_emit(config, name, event)
        Telemetry.emit_emitted(name, attrs.type, attrs.source)
        {:ok, event}

      {:error, :event, changeset, _changes} ->
        {:error, changeset}

      {:error, :oban_job, reason, _changes} ->
        {:error, reason}
    end
  end

  defp reenqueue_event(config, name, event) do
    job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
    changeset = Forja.Workers.ProcessEventWorker.new(job_args)
    Oban.insert(config.oban_name, changeset)
  end

  @doc """
  Adds event emission steps to an existing `Ecto.Multi`.

  Allows composing event emission atomically with other database operations
  in the same transaction. The caller is responsible for executing
  `Repo.transaction/1` on the returned Multi.

  ## GenStage fast-path and emit_multi

  Unlike `emit/3`, `emit_multi` does NOT trigger PubSub broadcast automatically.
  Doing so inside an `Ecto.Multi.run` step would fire those side-effects while the
  caller's transaction is still open — creating a race condition where the GenStage
  consumer attempts to process the event before the commit completes.

  With `emit_multi`, the **Oban path is the sole delivery mechanism**. If the
  GenStage fast-path is also desired, the caller must invoke
  `Forja.notify_producers/2` after `Repo.transaction/1` returns successfully:

      case Repo.transaction(multi) do
        {:ok, %{order: order}} ->
          Forja.notify_producers(:my_app, event_id)
          {:ok, order}
        {:error, _, changeset, _} ->
          {:error, changeset}
      end

  This is intentional: the dual-path design guarantees delivery via Oban
  regardless, so missing the GenStage fast-path on the `emit_multi` path is
  safe by design.

  ## Options

    * `:payload_fn` - Function `(map() -> map())` that receives the previous
      Multi results and returns the payload (required if the payload depends
      on previous results)
    * `:payload` - Static map with event data (alternative to `:payload_fn`)
    * `:meta` - Map with metadata (default: `%{}`)
    * `:source` - String identifying the origin (default: `nil`)
    * `:idempotency_key` - Optional string key for deduplication (default: `nil`)

  ## Idempotency

  When `:idempotency_key` is provided and an event with the same key already exists,
  the Multi step short-circuits:

    * If found with `processed_at` set: returns `{:ok, :already_processed}`
    * If found with `processed_at: nil`: re-enqueues the Oban job and returns
      `{:ok, {:retrying, existing_event_id}}`
    * If not found: inserts normally

  ## Example

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:order, order_changeset)
      |> Forja.emit_multi(:billing, "order:created",
        payload_fn: fn %{order: order} -> %{"order_id" => order.id} end,
        source: "orders",
        idempotency_key: "order-created-\#{order_ref}"
      )
      |> Repo.transaction()
  """
  @spec emit_multi(Ecto.Multi.t(), atom(), String.t(), keyword()) :: Ecto.Multi.t()
  def emit_multi(multi, name, type, opts \\ []) do
    payload_fn = Keyword.get(opts, :payload_fn)
    static_payload = Keyword.get(opts, :payload, %{})
    meta = Keyword.get(opts, :meta, %{})
    source = Keyword.get(opts, :source)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    event_key = :"forja_event_#{type}"
    oban_key = :"forja_oban_#{type}"

    multi
    |> Ecto.Multi.run(event_key, fn _repo, changes ->
      config = Config.get(name)

      case check_idempotency(config, idempotency_key) do
        :proceed ->
          payload = resolve_payload(payload_fn, static_payload, changes)

          attrs =
            %{type: type, payload: payload, meta: meta, source: source}
            |> maybe_put_idempotency_key(idempotency_key)

          config.repo.insert(Event.changeset(%Event{}, attrs))

        {:already_processed, event} ->
          Telemetry.emit_deduplicated(name, idempotency_key, event.id)
          {:ok, :already_processed}

        {:retrying, event} ->
          Telemetry.emit_deduplicated(name, idempotency_key, event.id)
          reenqueue_event(config, name, event)
          {:ok, {:retrying, event.id}}
      end
    end)
    |> Ecto.Multi.run(oban_key, fn _repo, changes ->
      case Map.fetch!(changes, event_key) do
        :already_processed ->
          {:ok, :skipped}

        {:retrying, _event_id} ->
          {:ok, :skipped}

        %Event{} = event ->
          job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
          config = Config.get(name)
          changeset = Forja.Workers.ProcessEventWorker.new(job_args)
          Oban.insert(config.oban_name, changeset)
      end
    end)
  end

  @doc """
  Notifies the GenStage producer of a new event by ID via PubSub broadcast.

  Intended for use after a successful `Repo.transaction/1` on a Multi built
  with `emit_multi/4`, to trigger the fast-path GenStage processing in addition
  to the guaranteed Oban path.

  The `EventProducer` subscribes to the PubSub topic during its `init/1` and
  receives the broadcast as a `handle_info/2` message. A direct cast to the
  producer is not needed and would cause duplicate enqueuing of the same event.

  ## Example

      case Repo.transaction(multi) do
        {:ok, %{forja_event_order_created: %Forja.Event{} = event}} ->
          Forja.notify_producers(:my_app, event.id)
          {:ok, event}
        {:error, _, changeset, _} ->
          {:error, changeset}
      end
  """
  @spec notify_producers(atom(), String.t()) :: :ok
  def notify_producers(name, event_id) do
    config = Config.get(name)
    topic = "#{config.event_topic_prefix}:events"
    Phoenix.PubSub.broadcast(config.pubsub, topic, {:forja_event, event_id})
  end

  @impl Supervisor
  def init(%Config{} = config) do
    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(config.name, table, catch_all)

    children = [
      {ObanListener, name: config.name},
      {EventProducer,
       name: config.name,
       pubsub: config.pubsub,
       event_topic_prefix: config.event_topic_prefix},
      {EventConsumer,
       name: config.name,
       producer: EventProducer.producer_name(config.name),
       max_demand: config.consumer_pool_size}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp after_emit(_config, name, event) do
    notify_producers(name, event.id)
  end

  defp supervisor_name(name) do
    Module.concat([Forja, Supervisor, name])
  end

  defp maybe_put_idempotency_key(attrs, nil), do: attrs
  defp maybe_put_idempotency_key(attrs, key), do: Map.put(attrs, :idempotency_key, key)

  defp resolve_payload(nil, static_payload, _changes), do: static_payload
  defp resolve_payload(payload_fn, _static_payload, changes), do: payload_fn.(changes)
end
```

**Arquivo de teste:** `test/forja_test.exs`

```elixir
defmodule ForjaTest do
  use Forja.DataCase, async: false

  alias Forja.Event

  defmodule EmitTestHandler do
    @moduledoc "Test handler for event emission."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["emit_test:created", "emit_test:multi"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:emit_test), {:handled, event.type, event.payload})
      :ok
    end
  end

  setup do
    Process.register(self(), :emit_test)

    start_supervised!({Phoenix.PubSub, name: Forja.EmitTestPubSub})

    start_supervised!(
      {Forja,
       name: :emit_test,
       repo: Repo,
       pubsub: Forja.EmitTestPubSub,
       oban_name: Forja.TestOban,
       handlers: [EmitTestHandler]}
    )

    :ok
  end

  describe "emit/3" do
    test "persists event and returns it" do
      assert {:ok, event} =
               Forja.emit(:emit_test, "emit_test:created",
                 payload: %{"order_id" => "123"},
                 source: "test"
               )

      assert event.type == "emit_test:created"
      assert event.payload == %{"order_id" => "123"}
      assert event.source == "test"
      assert event.id != nil

      persisted = Repo.get!(Event, event.id)
      assert persisted.type == "emit_test:created"
    end

    test "applies default values for optional fields" do
      assert {:ok, event} = Forja.emit(:emit_test, "emit_test:created")

      assert event.payload == %{}
      assert event.meta == %{}
      assert event.source == nil
    end
  end

  describe "emit/3 with idempotency_key" do
    test "emits normally when no duplicate exists" do
      assert {:ok, event} =
               Forja.emit(:emit_test, "emit_test:created",
                 payload: %{"order_id" => "123"},
                 idempotency_key: "unique-key-abc"
               )

      assert event.idempotency_key == "unique-key-abc"
    end

    test "returns already_processed when duplicate is processed" do
      {:ok, event} =
        Forja.emit(:emit_test, "emit_test:created",
          payload: %{"order_id" => "123"},
          idempotency_key: "idem-key-processed"
        )

      Repo.update!(Event.mark_processed_changeset(event))

      assert {:ok, :already_processed} =
               Forja.emit(:emit_test, "emit_test:created",
                 payload: %{"order_id" => "456"},
                 idempotency_key: "idem-key-processed"
               )
    end

    test "returns retrying when duplicate is unprocessed" do
      {:ok, event} =
        Forja.emit(:emit_test, "emit_test:created",
          payload: %{"order_id" => "123"},
          idempotency_key: "idem-key-retrying"
        )

      assert {:ok, :retrying, event_id} =
               Forja.emit(:emit_test, "emit_test:created",
                 payload: %{"order_id" => "456"},
                 idempotency_key: "idem-key-retrying"
               )

      assert event_id == event.id
    end

    test "emits normally without idempotency_key" do
      assert {:ok, event1} = Forja.emit(:emit_test, "emit_test:created", payload: %{"a" => 1})
      assert {:ok, event2} = Forja.emit(:emit_test, "emit_test:created", payload: %{"a" => 1})

      assert event1.id != event2.id
    end
  end

  describe "emit_multi/4" do
    test "adds event emission steps to an existing Multi" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:setup, fn _repo, _changes ->
          {:ok, %{some_id: "abc"}}
        end)
        |> Forja.emit_multi(:emit_test, "emit_test:multi",
          payload_fn: fn %{setup: setup} -> %{"ref" => setup.some_id} end,
          source: "multi_test"
        )

      assert {:ok, result} = Repo.transaction(multi)
      assert result[:"forja_event_emit_test:multi"].type == "emit_test:multi"
      assert result[:"forja_event_emit_test:multi"].payload == %{"ref" => "abc"}
    end

    test "supports static payload" do
      multi =
        Ecto.Multi.new()
        |> Forja.emit_multi(:emit_test, "emit_test:multi",
          payload: %{"static" => true}
        )

      assert {:ok, result} = Repo.transaction(multi)
      assert result[:"forja_event_emit_test:multi"].payload == %{"static" => true}
    end
  end
end
```

---

### 3.12 `Forja.Testing`

**Arquivo:** `lib/forja/testing.ex`

```elixir
defmodule Forja.Testing do
  @moduledoc """
  Helpers for testing applications that use Forja.

  Provides functions to verify that events were emitted and to
  process pending events synchronously in tests.

  ## Inline mode

  In tests, Forja can be configured to process events synchronously
  without GenStage or Oban:

      start_supervised!(
        {Forja,
         name: :test,
         repo: MyApp.Repo,
         pubsub: MyApp.PubSub,
         handlers: [MyHandler]}
      )

  ## Usage example

      defmodule MyApp.OrderTest do
        use MyApp.DataCase

        import Forja.Testing

        test "emitting order event" do
          Forja.emit(:test, "order:created", payload: %{"id" => 1})

          assert_event_emitted(:test, "order:created")
          assert_event_emitted(:test, "order:created", %{"id" => 1})
        end
      end
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Forja.Config
  alias Forja.Event

  @doc """
  Asserts that an event of the specified type was emitted in the `name` instance.

  Optionally verifies that the payload contains the specified fields.
  """
  @spec assert_event_emitted(atom(), String.t(), map()) :: Event.t()
  def assert_event_emitted(name, type, payload_match \\ %{}) do
    config = Config.get(name)
    events = fetch_events(config.repo, type)

    assert events != [],
           "Expected event of type #{inspect(type)} to be emitted, but none found."

    matching = filter_by_payload(events, payload_match)

    assert matching != [],
           "Found #{length(events)} event(s) of type #{inspect(type)}, " <>
             "but none matched payload #{inspect(payload_match)}. " <>
             "Payloads found: #{inspect(Enum.map(events, & &1.payload))}"

    List.first(matching)
  end

  @doc """
  Asserts that NO event of the specified type was emitted in the `name` instance.
  """
  @spec refute_event_emitted(atom(), String.t()) :: :ok
  def refute_event_emitted(name, type) do
    config = Config.get(name)
    events = fetch_events(config.repo, type)

    assert events == [],
           "Expected no events of type #{inspect(type)}, but found #{length(events)}."

    :ok
  end

  @doc """
  Synchronously processes all pending events (without `processed_at`).

  Useful for tests that need to ensure all handlers have been executed
  before making assertions.
  """
  @spec process_all_pending(atom()) :: :ok
  def process_all_pending(name) do
    config = Config.get(name)

    events =
      config.repo.all(
        from(e in Event, where: is_nil(e.processed_at), order_by: [asc: e.inserted_at])
      )

    Enum.each(events, fn event ->
      Forja.Processor.process(name, event.id, :inline)
    end)

    :ok
  end

  @doc """
  Asserts that an event with the given idempotency key was deduplicated.

  Verifies that exactly one event exists with the specified key, confirming
  deduplication worked correctly.
  """
  @spec assert_event_deduplicated(atom(), String.t()) :: Event.t()
  def assert_event_deduplicated(name, idempotency_key) do
    config = Config.get(name)

    events =
      config.repo.all(
        from(e in Event, where: e.idempotency_key == ^idempotency_key)
      )

    assert length(events) == 1,
           "Expected exactly 1 event with idempotency_key #{inspect(idempotency_key)}, " <>
             "but found #{length(events)}."

    List.first(events)
  end

  @doc """
  Invokes a handler directly with a fabricated event.

  Useful for testing handlers in isolation without emitting real events.
  """
  @spec invoke_handler(module(), String.t(), map(), map()) :: :ok | {:error, term()}
  def invoke_handler(handler_module, type, payload \\ %{}, meta \\ %{}) do
    event = %Event{
      id: Ecto.UUID.generate(),
      type: type,
      payload: payload,
      meta: meta,
      inserted_at: DateTime.utc_now()
    }

    handler_module.handle_event(event, meta)
  end

  defp fetch_events(repo, type) do
    repo.all(
      from(e in Event, where: e.type == ^type, order_by: [asc: e.inserted_at])
    )
  end

  defp filter_by_payload(events, payload_match) when map_size(payload_match) == 0 do
    events
  end

  defp filter_by_payload(events, payload_match) do
    Enum.filter(events, fn event ->
      Enum.all?(payload_match, fn {key, value} ->
        string_key = to_string(key)
        Map.get(event.payload, string_key) == value
      end)
    end)
  end
end
```

**Arquivo de teste:** `test/forja/testing_test.exs`

```elixir
defmodule Forja.TestingTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry

  defmodule TestingHandler do
    @moduledoc "Test handler for Forja.Testing."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["testing:created"]

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  setup do
    config =
      Config.new(
        name: :testing_test,
        repo: Repo,
        pubsub: Forja.TestPubSub,
        handlers: [TestingHandler]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:testing_test, table, catch_all)

    :ok
  end

  describe "assert_event_emitted/3" do
    test "passes when event exists" do
      insert_event!("testing:created", %{"order_id" => "123"})

      event = Forja.Testing.assert_event_emitted(:testing_test, "testing:created")
      assert event.type == "testing:created"
    end

    test "passes with payload match" do
      insert_event!("testing:created", %{"order_id" => "123"})

      event =
        Forja.Testing.assert_event_emitted(
          :testing_test,
          "testing:created",
          %{"order_id" => "123"}
        )

      assert event.payload["order_id"] == "123"
    end

    test "raises when no events exist" do
      assert_raise ExUnit.AssertionError, ~r/Expected event/, fn ->
        Forja.Testing.assert_event_emitted(:testing_test, "testing:created")
      end
    end

    test "raises when payload does not match" do
      insert_event!("testing:created", %{"order_id" => "123"})

      assert_raise ExUnit.AssertionError, ~r/none matched payload/, fn ->
        Forja.Testing.assert_event_emitted(
          :testing_test,
          "testing:created",
          %{"order_id" => "999"}
        )
      end
    end
  end

  describe "refute_event_emitted/2" do
    test "passes when no events exist" do
      assert :ok = Forja.Testing.refute_event_emitted(:testing_test, "testing:created")
    end

    test "raises when events exist" do
      insert_event!("testing:created", %{})

      assert_raise ExUnit.AssertionError, ~r/Expected no events/, fn ->
        Forja.Testing.refute_event_emitted(:testing_test, "testing:created")
      end
    end
  end

  describe "process_all_pending/1" do
    test "processes all unprocessed events" do
      insert_event!("testing:created", %{"a" => 1})
      insert_event!("testing:created", %{"b" => 2})

      Forja.Testing.process_all_pending(:testing_test)

      import Ecto.Query

      unprocessed =
        Repo.all(from(e in Event, where: is_nil(e.processed_at)))

      assert unprocessed == []
    end
  end

  describe "assert_event_deduplicated/2" do
    test "passes when exactly one event with idempotency_key exists" do
      insert_event_with_key!("testing:created", %{}, "dedup-key-1")

      event = Forja.Testing.assert_event_deduplicated(:testing_test, "dedup-key-1")
      assert event.idempotency_key == "dedup-key-1"
    end

    test "raises when no events with idempotency_key exist" do
      assert_raise ExUnit.AssertionError, ~r/Expected exactly 1 event/, fn ->
        Forja.Testing.assert_event_deduplicated(:testing_test, "nonexistent-key")
      end
    end
  end

  describe "invoke_handler/4" do
    test "calls handler with fabricated event" do
      assert :ok =
               Forja.Testing.invoke_handler(
                 TestingHandler,
                 "testing:created",
                 %{"order_id" => "123"}
               )
    end
  end

  defp insert_event!(type, payload) do
    %Event{}
    |> Event.changeset(%{type: type, payload: payload, meta: %{}})
    |> Repo.insert!()
  end

  defp insert_event_with_key!(type, payload, idempotency_key) do
    %Event{}
    |> Event.changeset(%{type: type, payload: payload, meta: %{}, idempotency_key: idempotency_key})
    |> Repo.insert!()
  end
end
```

---

## 4. Migration Generator

**Arquivo:** `lib/mix/tasks/forja.install.ex`

```elixir
defmodule Mix.Tasks.Forja.Install do
  @moduledoc """
  Generates the migration for the `forja_events` table.

  ## Usage

      mix forja.install
  """

  use Mix.Task

  import Mix.Generator

  @shortdoc "Generates the forja_events table migration"

  @impl Mix.Task
  def run(_args) do
    path = migrations_path()
    timestamp = timestamp()
    file = Path.join(path, "#{timestamp}_create_forja_events.exs")

    create_directory(path)
    create_file(file, migration_template())

    Mix.shell().info("""

    Migration gerada em #{file}.

    Proximo passo:

        mix ecto.migrate
    """)
  end

  defp migrations_path do
    Path.join(["priv", "repo", "migrations"])
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()

    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"

  defp migration_template do
    """
    defmodule CreateForjaEvents do
      use Ecto.Migration

      def change do
        create table(:forja_events, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :type, :string, null: false
          add :payload, :map, default: "{}"
          add :meta, :map, default: "{}"
          add :source, :string
          add :processed_at, :utc_datetime_usec
          add :idempotency_key, :string
          add :reconciliation_attempts, :integer, default: 0, null: false

          timestamps(type: :utc_datetime_usec, updated_at: false)
        end

        create index(:forja_events, [:type])
        create index(:forja_events, [:source])
        create index(:forja_events, [:inserted_at])
        create index(:forja_events, [:type, :source])

        create index(:forja_events, [:processed_at],
                 where: "processed_at IS NULL",
                 name: :forja_events_unprocessed
               )

        create unique_index(:forja_events, [:idempotency_key],
                 where: "idempotency_key IS NOT NULL",
                 name: :forja_events_idempotency_key_index
               )

        create index(:forja_events, [:processed_at, :inserted_at, :reconciliation_attempts],
                 where: "processed_at IS NULL",
                 name: :forja_events_reconciliation
               )
      end
    end
    """
  end
end
```

---

## 5. Guia de Integracao

### Passo 1 -- Adicionar dependencia

```elixir
defp deps do
  [
    {:forja, "~> 0.1"},
  ]
end
```

```bash
mix deps.get
```

### Passo 2 -- Gerar migration

```bash
mix forja.install
```

Isso gera `priv/repo/migrations/YYYYMMDDHHMMSS_create_forja_events.exs`.

### Passo 3 -- Rodar migration

```bash
mix ecto.migrate
```

### Passo 4 -- Configurar Oban queue

No `config/config.exs`, adicionar as queues `:forja_events` e `:forja_reconciliation` na configuracao do Oban. Opcionalmente, registrar o `ReconciliationWorker` no crontab:

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

O intervalo do cron (`0 * * * *` = uma vez por hora) deve ser ajustado de acordo com o `interval_minutes` configurado na instancia Forja. Por exemplo, para `interval_minutes: 30`, use `"0,30 * * * *"`. O `ReconciliationWorker` verifica automaticamente se a reconciliacao esta habilitada antes de executar.

### Passo 5 -- Adicionar Forja na supervision tree

```elixir
defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      {Forja,
       name: :my_app,
       repo: MyApp.Repo,
       pubsub: MyApp.PubSub,
       oban_name: Oban,
       handlers: [
         MyApp.Events.OrderNotifier,
         MyApp.Events.AnalyticsTracker
       ],
       dead_letter: MyApp.Events.DeadLetterHandler,
       reconciliation: [
         enabled: true,
         interval_minutes: 60,
         threshold_minutes: 15,
         max_retries: 3
       ]},
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

A Forja deve ser iniciada **apos** Repo, PubSub e Oban (depende dos tres).

As opcoes `dead_letter` e `reconciliation` sao **opcionais**. Se `dead_letter` nao for configurado (`nil`), apenas eventos de telemetry sao emitidos para dead letters. Se `reconciliation` nao for passado, os valores default sao usados (habilitado, 60min intervalo, 15min threshold, 3 retries).

### Passo 6 -- Criar handlers

```elixir
defmodule MyApp.Events.OrderNotifier do
  @moduledoc "Sends notifications for order events."

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

### Passo 7 -- Emitir eventos

**Emissao simples:**

```elixir
Forja.emit(:my_app, "order:created",
  payload: %{"order_id" => order.id, "total" => order.total},
  source: "orders"
)
```

**Emissao transacional (recomendada):**

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

---

## 6. Exemplo Completo -- Billing

### Schema do dominio

```elixir
defmodule Billing.Payment do
  @moduledoc "Payment schema."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "payments" do
    field :amount, :integer
    field :currency, :string, default: "BRL"
    field :status, :string, default: "pending"
    field :customer_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:amount, :currency, :customer_id])
    |> validate_required([:amount, :customer_id])
    |> validate_number(:amount, greater_than: 0)
  end
end
```

### Contexto de billing

```elixir
defmodule Billing do
  @moduledoc "Billing context with event emission via Forja."

  alias Billing.Payment
  alias MyApp.Repo

  @doc "Records a received payment."
  @spec receive_payment(map()) :: {:ok, Payment.t()} | {:error, Ecto.Changeset.t()}
  def receive_payment(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:payment, Payment.changeset(%Payment{}, attrs))
    |> Ecto.Multi.update(:confirm, fn %{payment: payment} ->
      Ecto.Changeset.change(payment, status: "confirmed")
    end)
    |> Forja.emit_multi(:billing, "payment:received",
      payload_fn: fn %{payment: payment} ->
        %{
          "payment_id" => payment.id,
          "amount" => payment.amount,
          "currency" => payment.currency,
          "customer_id" => payment.customer_id
        }
      end,
      source: "billing"
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{confirm: payment}} -> {:ok, payment}
      {:error, :payment, changeset, _} -> {:error, changeset}
    end
  end

  @doc "Records a payment failure."
  @spec fail_payment(Payment.t(), String.t()) :: {:ok, Payment.t()} | {:error, term()}
  def fail_payment(payment, reason) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:payment, Ecto.Changeset.change(payment, status: "failed"))
    |> Forja.emit_multi(:billing, "payment:failed",
      payload_fn: fn %{payment: p} ->
        %{
          "payment_id" => p.id,
          "reason" => reason,
          "customer_id" => p.customer_id
        }
      end,
      source: "billing"
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{payment: payment}} -> {:ok, payment}
      {:error, :payment, changeset, _} -> {:error, changeset}
    end
  end

  @doc "Creates an invoice."
  @spec create_invoice(map()) :: {:ok, map()} | {:error, term()}
  def create_invoice(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:invoice, fn _repo, _changes ->
      {:ok, Map.put(attrs, "id", Ecto.UUID.generate())}
    end)
    |> Forja.emit_multi(:billing, "invoice:created",
      payload_fn: fn %{invoice: invoice} ->
        %{"invoice_id" => invoice["id"], "customer_id" => invoice["customer_id"]}
      end,
      source: "billing"
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{invoice: invoice}} -> {:ok, invoice}
      {:error, _, reason, _} -> {:error, reason}
    end
  end
end
```

### Handler: BillingNotifier

```elixir
defmodule Billing.Events.BillingNotifier do
  @moduledoc "Sends notifications for billing events."

  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: ["payment:received", "payment:failed", "invoice:created"]

  @impl Forja.Handler
  def handle_event(%Forja.Event{type: "payment:received"} = event, _meta) do
    MyApp.Mailer.send_payment_confirmation(event.payload["customer_id"], event.payload["amount"])
    :ok
  end

  def handle_event(%Forja.Event{type: "payment:failed"} = event, _meta) do
    MyApp.Mailer.send_payment_failure(event.payload["customer_id"], event.payload["reason"])
    :ok
  end

  def handle_event(%Forja.Event{type: "invoice:created"} = event, _meta) do
    MyApp.Mailer.send_invoice(event.payload["customer_id"], event.payload["invoice_id"])
    :ok
  end
end
```

### Handler: BillingAnalytics

```elixir
defmodule Billing.Events.BillingAnalytics do
  @moduledoc "Tracks billing metrics for analytics."

  @behaviour Forja.Handler

  @impl Forja.Handler
  def event_types, do: ["payment:received", "payment:failed"]

  @impl Forja.Handler
  def handle_event(%Forja.Event{type: "payment:received"} = event, _meta) do
    :telemetry.execute(
      [:billing, :payment, :received],
      %{amount: event.payload["amount"]},
      %{currency: event.payload["currency"]}
    )

    :ok
  end

  def handle_event(%Forja.Event{type: "payment:failed"} = event, _meta) do
    :telemetry.execute(
      [:billing, :payment, :failed],
      %{count: 1},
      %{reason: event.payload["reason"]}
    )

    :ok
  end
end
```

### Supervision tree do billing

```elixir
defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      {Forja,
       name: :billing,
       repo: MyApp.Repo,
       pubsub: MyApp.PubSub,
       handlers: [
         Billing.Events.BillingNotifier,
         Billing.Events.BillingAnalytics
       ],
       dead_letter: Billing.Events.BillingDeadLetter,
       reconciliation: [enabled: true, interval_minutes: 30, threshold_minutes: 10, max_retries: 5]},
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Teste de integracao

```elixir
defmodule Billing.BillingTest do
  use MyApp.DataCase, async: false

  import Forja.Testing

  describe "receive_payment/1" do
    test "emits payment:received event" do
      attrs = %{amount: 5000, currency: "BRL", customer_id: Ecto.UUID.generate()}

      assert {:ok, payment} = Billing.receive_payment(attrs)
      assert payment.status == "confirmed"

      event = assert_event_emitted(:billing, "payment:received", %{"amount" => 5000})
      assert event.payload["payment_id"] == payment.id
      assert event.source == "billing"
    end
  end

  describe "fail_payment/2" do
    test "emits payment:failed event" do
      {:ok, payment} =
        Billing.receive_payment(%{
          amount: 3000,
          customer_id: Ecto.UUID.generate()
        })

      assert {:ok, failed} = Billing.fail_payment(payment, "insufficient_funds")
      assert failed.status == "failed"

      assert_event_emitted(:billing, "payment:failed", %{"reason" => "insufficient_funds"})
    end
  end

  describe "create_invoice/1" do
    test "emits invoice:created event" do
      customer_id = Ecto.UUID.generate()

      assert {:ok, invoice} =
               Billing.create_invoice(%{"customer_id" => customer_id})

      assert_event_emitted(:billing, "invoice:created", %{"customer_id" => customer_id})
    end
  end
end
```

---

## 7. Checklist de Implementacao

Ordem exata de criacao de arquivos, com dependencias entre parenteses.

### Infraestrutura do projeto

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 1 | `mix.exs` | nenhuma |
| 2 | `.formatter.exs` | nenhuma |
| 3 | `lib/forja/config.ex` | nenhuma |
| 4 | `test/forja/config_test.exs` | `Forja.Config` |

### Schema e behaviour

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 5 | `lib/forja/event.ex` | nenhuma |
| 6 | `test/forja/event_test.exs` | `Forja.Event` |
| 7 | `lib/forja/handler.ex` | `Forja.Event` (para typespec) |
| 8 | `test/forja/handler_test.exs` | `Forja.Handler`, `Forja.Event` |
| 9 | `lib/forja/dead_letter.ex` | `Forja.Event` (para typespec) |
| 10 | `test/forja/dead_letter_test.exs` | `Forja.DeadLetter`, `Forja.Event` |

### Infraestrutura interna

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 11 | `lib/forja/registry.ex` | `Forja.Handler` |
| 12 | `test/forja/registry_test.exs` | `Forja.Registry`, `Forja.Handler` |
| 13 | `lib/forja/advisory_lock.ex` | nenhuma (usa Repo generico) |
| 14 | `test/forja/advisory_lock_test.exs` | `Forja.AdvisoryLock`, Repo de teste |
| 15 | `lib/forja/telemetry.ex` | nenhuma |
| 16 | `test/forja/telemetry_test.exs` | `Forja.Telemetry` |
| 17 | `lib/forja/oban_listener.ex` | `Forja.Config`, `Forja.DeadLetter`, `Forja.Event`, `Forja.Telemetry` |
| 18 | `test/forja/oban_listener_test.exs` | `Forja.ObanListener`, Repo de teste |

### Processamento

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 19 | `lib/forja/processor.ex` | `Config`, `AdvisoryLock`, `Event`, `Registry`, `Telemetry` |
| 20 | `test/forja/processor_test.exs` | `Forja.Processor`, Repo de teste |

### Pipeline GenStage

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 21 | `lib/forja/event_producer.ex` | `Forja.Telemetry` |
| 22 | `test/support/test_consumer.ex` | GenStage |
| 23 | `test/forja/event_producer_test.exs` | `Forja.EventProducer`, `Forja.TestConsumer` |
| 24 | `lib/forja/event_worker.ex` | `Forja.Processor` |
| 25 | `lib/forja/event_consumer.ex` | `Forja.EventWorker`, `Forja.EventProducer` |
| 26 | `test/forja/event_consumer_test.exs` | `Forja.EventConsumer`, Repo de teste |

### Oban workers

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 27 | `lib/forja/workers/process_event_worker.ex` | `Forja.Processor` |
| 28 | `test/forja/workers/process_event_worker_test.exs` | `ProcessEventWorker`, Repo de teste |
| 29 | `lib/forja/workers/reconciliation_worker.ex` | `Forja.Config`, `Forja.DeadLetter`, `Forja.Event`, `Forja.Processor`, `Forja.Telemetry` |
| 30 | `test/forja/workers/reconciliation_worker_test.exs` | `ReconciliationWorker`, Repo de teste |

### Modulo principal

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 31 | `lib/forja.ex` | Todos os modulos anteriores |
| 32 | `test/forja_test.exs` | `Forja`, Repo de teste |

### Testing helpers

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 33 | `lib/forja/testing.ex` | `Forja.Config`, `Forja.Event`, `Forja.Processor` |
| 34 | `test/forja/testing_test.exs` | `Forja.Testing`, Repo de teste |

### Mix task

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 35 | `lib/mix/tasks/forja.install.ex` | nenhuma |

### Suporte de teste

| # | Arquivo | Dependencias |
|---|---------|-------------|
| 36 | `test/test_helper.exs` | nenhuma |
| 37 | `test/support/data_case.ex` | Ecto.Sandbox |
| 38 | `test/support/repo.ex` | Ecto |
| 39 | `config/config.exs` | nenhuma |
| 40 | `config/test.exs` | nenhuma |

### Suporte de teste -- Arquivos

**`test/test_helper.exs`:**

```elixir
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Forja.TestRepo, :manual)
```

**`test/support/data_case.ex`:**

```elixir
defmodule Forja.DataCase do
  @moduledoc """
  Case template for tests that require database access.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Forja.TestRepo, as: Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Forja.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
```

**`test/support/repo.ex`:**

```elixir
defmodule Forja.TestRepo do
  @moduledoc "Test Repo for Forja."

  use Ecto.Repo,
    otp_app: :forja,
    adapter: Ecto.Adapters.Postgres
end
```

**`config/config.exs`:**

```elixir
import Config

config :forja, ecto_repos: [Forja.TestRepo]

import_config "#{config_env()}.exs"
```

**`config/test.exs`:**

```elixir
import Config

config :forja, Forja.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "forja_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :logger, level: :warning

config :forja, Oban,
  testing: :manual
```

---

**Total: 40 arquivos na implementacao completa.**
