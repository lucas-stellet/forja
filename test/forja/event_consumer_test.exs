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
