defmodule Forja.CorrelationTest do
  use Forja.DataCase, async: false

  alias Forja.TestEvents.EmitTestCreated
  alias Forja.TestEvents.EmitTestMulti

  defmodule CorrelationTestHandler do
    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["emit_test:created", "emit_test:multi"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:correlation_test), {:handled, event.type, event.payload})
      :ok
    end
  end

  setup do
    Process.register(self(), :correlation_test)

    start_supervised!({Phoenix.PubSub, name: Forja.CorrelationTestPubSub})

    start_supervised!(
      {Oban, name: Forja.CorrelationTestOban, repo: Repo, queues: false, testing: :inline}
    )

    start_supervised!(
      {Forja,
       name: :correlation_test,
       repo: Repo,
       pubsub: Forja.CorrelationTestPubSub,
       oban_name: Forja.CorrelationTestOban,
       migration_check: false,
       handlers: [CorrelationTestHandler]}
    )

    :ok
  end

  describe "emit/3 correlation" do
    test "root event gets a non-nil correlation_id" do
      assert {:ok, event} =
               Forja.emit(:correlation_test, EmitTestCreated,
                 payload: %{order_id: "123"},
                 source: "test"
               )

      assert event.correlation_id != nil
      assert is_binary(event.correlation_id)
    end

    test "root event has nil causation_id" do
      assert {:ok, event} =
               Forja.emit(:correlation_test, EmitTestCreated,
                 payload: %{order_id: "123"},
                 source: "test"
               )

      assert event.causation_id == nil
    end

    test "each root event gets a unique correlation_id" do
      assert {:ok, event1} = Forja.emit(:correlation_test, EmitTestCreated, payload: %{})
      assert {:ok, event2} = Forja.emit(:correlation_test, EmitTestCreated, payload: %{})

      assert event1.correlation_id != event2.correlation_id
    end

    test "explicit correlation_id is preserved" do
      explicitCorrelationId = Ecto.UUID.generate()

      assert {:ok, event} =
               Forja.emit(:correlation_test, EmitTestCreated,
                 payload: %{order_id: "123"},
                 correlation_id: explicitCorrelationId
               )

      assert event.correlation_id == explicitCorrelationId
    end

    test "explicit causation_id is preserved" do
      explicitCausationId = Ecto.UUID.generate()

      assert {:ok, event} =
               Forja.emit(:correlation_test, EmitTestCreated,
                 payload: %{order_id: "123"},
                 causation_id: explicitCausationId
               )

      assert event.causation_id == explicitCausationId
    end
  end

  describe "emit_multi/4 correlation" do
    test "emit_multi generates correlation_id" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:setup, fn _repo, _changes ->
          {:ok, %{some_id: "abc"}}
        end)
        |> Forja.emit_multi(:correlation_test, EmitTestMulti,
          payload_fn: fn %{setup: setup} -> %{ref: setup.some_id} end,
          source: "multi_test"
        )

      assert {:ok, result} = Repo.transaction(multi)
      event = result[:"forja_event_emit_test:multi"]
      assert event.correlation_id != nil
      assert is_binary(event.correlation_id)
    end

    test "emit_multi with explicit correlation_id is preserved" do
      explicitCorrelationId = Ecto.UUID.generate()

      multi =
        Ecto.Multi.new()
        |> Forja.emit_multi(:correlation_test, EmitTestMulti,
          payload: %{static: true},
          correlation_id: explicitCorrelationId
        )

      assert {:ok, result} = Repo.transaction(multi)
      event = result[:"forja_event_emit_test:multi"]
      assert event.correlation_id == explicitCorrelationId
    end

    test "emit_multi causation_id is nil when not provided" do
      multi =
        Ecto.Multi.new()
        |> Forja.emit_multi(:correlation_test, EmitTestMulti, payload: %{static: true})

      assert {:ok, result} = Repo.transaction(multi)
      event = result[:"forja_event_emit_test:multi"]
      assert event.causation_id == nil
    end
  end

  # Propagation tests are in correlation_propagation_test.exs
  # (separate module to avoid ExUnit child registry conflicts)
end
