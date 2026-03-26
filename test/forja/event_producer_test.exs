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
    expected = Module.concat([Forja, Producer, :my_app])
    assert EventProducer.producer_name(:my_app) == expected
  end

  test "notify/2 buffers event IDs for consumption" do
    EventProducer.notify(:producer_test, "event-1")
    EventProducer.notify(:producer_test, "event-2")

    {:ok, consumer_pid} =
      GenStage.start_link(Forja.TestConsumer, %{
        test_pid: self(),
        subscribe_to: EventProducer.producer_name(:producer_test)
      })

    assert_receive {:consumed, "event-1"}, 1_000
    assert_receive {:consumed, "event-2"}, 1_000

    GenStage.stop(consumer_pid)
  end

  test "handles PubSub messages" do
    {:ok, consumer_pid} =
      GenStage.start_link(Forja.TestConsumer, %{
        test_pid: self(),
        subscribe_to: EventProducer.producer_name(:producer_test)
      })

    Phoenix.PubSub.broadcast(
      Forja.ProducerTestPubSub,
      "test_forja:events",
      {:forja_event, "pubsub-event-1"}
    )

    assert_receive {:consumed, "pubsub-event-1"}, 1_000

    GenStage.stop(consumer_pid)
  end
end
