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

      Forja.emit(:my_app, MyApp.Events.OrderCreated,
        payload: %{order_id: order.id, amount_cents: order.total},
        source: "orders"
      )

  See `Forja.Event.Schema` for how to define typed event schemas.

  ## Idempotent emission

      Forja.emit(:my_app, MyApp.Events.OrderCreated,
        payload: %{order_id: order.id, amount_cents: order.total},
        source: "orders",
        idempotency_key: "order-created-\#{order.id}"
      )

  ## Transactional emission

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:order, order_changeset)
      |> Forja.emit_multi(:my_app, MyApp.Events.OrderCreated,
        payload_fn: fn %{order: order} -> %{order_id: order.id, amount_cents: order.total} end,
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
  alias Forja.Workers.ProcessEventWorker

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

  The `type` argument must be a module that uses `Forja.Event.Schema`.
  The payload is validated against the Zoi schema before persistence.
  Invalid payloads return `{:error, %Forja.ValidationError{}}` immediately
  without persisting.

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

  ## Schema-based emission

      Forja.emit(:my_app, MyApp.Events.OrderCreated,
        payload: %{user_id: "uuid-123", amount_cents: 500},
        source: "checkout"
      )

  ## Idempotency

  When `:idempotency_key` is provided, the function checks for an existing event
  with the same key before inserting:

    * If found with `processed_at` set: returns `{:ok, :already_processed}`
    * If found with `processed_at: nil`: re-enqueues the Oban job and returns
      `{:ok, :retrying, existing_event_id}`
    * If not found: emits normally
  """
  @spec emit(atom(), module(), keyword()) ::
          {:ok, Event.t()}
          | {:ok, :already_processed}
          | {:ok, :retrying, String.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, Forja.ValidationError.t()}
  def emit(name, type, opts \\ []) do
    config = Config.get(name)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    case resolve_event_type(type, opts) do
      {:ok, resolved_type, payload, schema_version} ->
        attrs =
          %{
            type: resolved_type,
            payload: payload,
            meta: Keyword.get(opts, :meta, %{}),
            source: Keyword.get(opts, :source),
            schema_version: schema_version
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

      {:error, %Forja.ValidationError{} = validation_error} ->
        Telemetry.emit_validation_failed(name, type, validation_error.errors)
        {:error, validation_error}
    end
  end

  defp resolve_event_type(schema_module, opts) when is_atom(schema_module) do
    Code.ensure_loaded(schema_module)

    unless function_exported?(schema_module, :__forja_event_schema__, 0) do
      raise ArgumentError,
            "#{inspect(schema_module)} is not a Forja.Event.Schema module. " <>
              "Did you forget `use Forja.Event.Schema`?"
    end

    raw_payload = Keyword.get(opts, :payload, %{})

    case schema_module.parse_payload(raw_payload) do
      {:ok, validated} ->
        string_keyed = stringify_keys(validated)
        {:ok, schema_module.event_type(), string_keyed, schema_module.schema_version()}

      {:error, errors} ->
        {:error, Forja.ValidationError.new(schema_module, errors)}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp check_idempotency(_config, nil), do: :proceed

  defp check_idempotency(config, idempotency_key) do
    case config.repo.one(from(e in Event, where: e.idempotency_key == ^idempotency_key, limit: 1)) do
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
        changeset = ProcessEventWorker.new(job_args)
        Oban.insert(config.oban_name, changeset)
      end)

    case config.repo.transaction(multi) do
      {:ok, %{event: event}} ->
        after_emit(config, name, event)
        Telemetry.emit_emitted(name, attrs.type, attrs.source, attrs.payload)
        {:ok, event}

      {:error, :event, changeset, _changes} ->
        {:error, changeset}

      {:error, :oban_job, reason, _changes} ->
        {:error, reason}
    end
  end

  defp reenqueue_event(config, name, event) do
    job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
    changeset = ProcessEventWorker.new(job_args)
    Oban.insert(config.oban_name, changeset)
  end

  @doc """
  Adds event emission steps to an existing `Ecto.Multi`.

  Like `emit/3`, the `type` argument must be a module that uses
  `Forja.Event.Schema`. The payload is validated inside the Multi step.
  If validation fails, the transaction is rolled back with
  `{:error, step_key, %Forja.ValidationError{}, changes}`.

  The caller is responsible for executing `Repo.transaction/1` on the returned Multi.

  ## GenStage fast-path and emit_multi

  Unlike `emit/3`, `emit_multi` does NOT trigger PubSub broadcast automatically.
  Doing so inside an `Ecto.Multi.run` step would fire those side-effects while the
  caller's transaction is still open -- creating a race condition where the GenStage
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
  @spec emit_multi(Ecto.Multi.t(), atom(), module(), keyword()) :: Ecto.Multi.t()
  def emit_multi(multi, name, type, opts \\ []) do
    payload_fn = Keyword.get(opts, :payload_fn)
    static_payload = Keyword.get(opts, :payload, %{})
    meta = Keyword.get(opts, :meta, %{})
    source = Keyword.get(opts, :source)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    type_string = resolve_type_string_for_key(type)
    event_key = :"forja_event_#{type_string}"
    oban_key = :"forja_oban_#{type_string}"

    multi
    |> Ecto.Multi.run(event_key, fn _repo, changes ->
      config = Config.get(name)

      case check_idempotency(config, idempotency_key) do
        :proceed ->
          raw_payload = resolve_payload(payload_fn, static_payload, changes)
          opts_for_resolve = [payload: raw_payload]

          case resolve_event_type(type, opts_for_resolve) do
            {:ok, resolved_type, validated_payload, schema_version} ->
              attrs =
                %{
                  type: resolved_type,
                  payload: validated_payload,
                  meta: meta,
                  source: source,
                  schema_version: schema_version
                }
                |> maybe_put_idempotency_key(idempotency_key)

              config.repo.insert(Event.changeset(%Event{}, attrs))

            {:error, %Forja.ValidationError{} = validation_error} ->
              Telemetry.emit_validation_failed(name, type, validation_error.errors)
              {:error, validation_error}
          end

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

        {:error, %Forja.ValidationError{}} ->
          {:error, :validation_failed}

        %Event{} = event ->
          job_args = %{event_id: event.id, forja_name: Atom.to_string(name)}
          config = Config.get(name)
          changeset = ProcessEventWorker.new(job_args)
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
       name: config.name, pubsub: config.pubsub, event_topic_prefix: config.event_topic_prefix},
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

  defp resolve_type_string_for_key(type) when is_binary(type), do: type
  defp resolve_type_string_for_key(module) when is_atom(module), do: module.event_type()

  defp resolve_payload(nil, static_payload, _changes), do: static_payload
  defp resolve_payload(payload_fn, _static_payload, changes), do: payload_fn.(changes)
end
