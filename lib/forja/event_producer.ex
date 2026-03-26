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
