defmodule ForjaTest do
  use Forja.DataCase, async: false

  alias Forja.Event
  alias Forja.TestEvents.EmitTestCreated
  alias Forja.TestEvents.EmitTestMulti

  defmodule EmitTestHandler do
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
    start_supervised!({Oban, name: Forja.TestOban, repo: Repo, queues: false, testing: :inline})

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
               Forja.emit(:emit_test, EmitTestCreated,
                 payload: %{order_id: "123"},
                 source: "test"
               )

      assert event.type == "emit_test:created"
      assert event.payload["order_id"] == "123"
      assert event.source == "test"
      assert event.id != nil

      persisted = Repo.get!(Event, event.id)
      assert persisted.type == "emit_test:created"
    end

    test "applies default values for optional fields" do
      assert {:ok, event} = Forja.emit(:emit_test, EmitTestCreated, payload: %{})

      assert event.meta == %{}
      assert event.source == nil
    end
  end

  describe "emit/3 with idempotency_key" do
    test "emits normally when no duplicate exists" do
      assert {:ok, event} =
               Forja.emit(:emit_test, EmitTestCreated,
                 payload: %{order_id: "123"},
                 idempotency_key: "unique-key-abc"
               )

      assert event.idempotency_key == "unique-key-abc"
    end

    test "returns already_processed when duplicate is processed" do
      {:ok, event} =
        Forja.emit(:emit_test, EmitTestCreated,
          payload: %{order_id: "123"},
          idempotency_key: "idem-key-processed"
        )

      Repo.update!(Event.mark_processed_changeset(event))

      assert {:ok, :already_processed} =
               Forja.emit(:emit_test, EmitTestCreated,
                 payload: %{order_id: "456"},
                 idempotency_key: "idem-key-processed"
               )
    end

    test "returns retrying when duplicate is unprocessed" do
      {:ok, event} =
        %Event{}
        |> Event.changeset(%{
          type: "emit_test:created",
          payload: %{"order_id" => "123"},
          idempotency_key: "idem-key-retrying"
        })
        |> Repo.insert()

      assert {:ok, :retrying, event_id} =
               Forja.emit(:emit_test, EmitTestCreated,
                 payload: %{order_id: "456"},
                 idempotency_key: "idem-key-retrying"
               )

      assert event_id == event.id
    end

    test "emits normally without idempotency_key" do
      assert {:ok, event1} = Forja.emit(:emit_test, EmitTestCreated, payload: %{a: 1})
      assert {:ok, event2} = Forja.emit(:emit_test, EmitTestCreated, payload: %{a: 1})

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
        |> Forja.emit_multi(:emit_test, EmitTestMulti,
          payload_fn: fn %{setup: setup} -> %{ref: setup.some_id} end,
          source: "multi_test"
        )

      assert {:ok, result} = Repo.transaction(multi)
      assert result[:"forja_event_emit_test:multi"].type == "emit_test:multi"
      assert result[:"forja_event_emit_test:multi"].payload["ref"] == "abc"
    end

    test "supports static payload" do
      multi =
        Ecto.Multi.new()
        |> Forja.emit_multi(:emit_test, EmitTestMulti, payload: %{static: true})

      assert {:ok, result} = Repo.transaction(multi)
      assert result[:"forja_event_emit_test:multi"].payload["static"] == true
    end
  end
end
