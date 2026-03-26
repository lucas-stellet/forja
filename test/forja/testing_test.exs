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
