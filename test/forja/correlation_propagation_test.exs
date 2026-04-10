defmodule Forja.CorrelationPropagationTest do
  use Forja.DataCase, async: false

  alias Forja.Event
  alias Forja.TestEvents.EmitTestCreated

  @moduletag capture_log: true

  defmodule ChainEvent do
    use Forja.Event.Schema, event_type: "correlation_test:chain"

    payload do
      field(:step, Zoi.string())
    end
  end

  defmodule PropagatingHandler do
    @behaviour Forja.Handler

    @impl true
    def event_types, do: ["emit_test:created"]

    @impl true
    def handle_event(%Event{} = _event, _meta) do
      {:ok, child} =
        Forja.emit(:propagation_test, ChainEvent, payload: %{step: "child"})

      send(Process.whereis(:propagation_test_pid), {:child_emitted, child})
      :ok
    end
  end

  setup do
    Process.register(self(), :propagation_test_pid)

    start_supervised!({Phoenix.PubSub, name: Forja.PropagationPubSub})

    start_supervised!(
      {Oban, name: Forja.PropagationOban, repo: Repo, queues: false, testing: :inline}
    )

    start_supervised!(
      {Forja,
       name: :propagation_test,
       repo: Repo,
       pubsub: Forja.PropagationPubSub,
       oban_name: Forja.PropagationOban,
       migration_check: false,
       handlers: [PropagatingHandler]}
    )

    :ok
  end

  test "child event inherits parent's correlation_id" do
    {:ok, parent} = Forja.emit(:propagation_test, EmitTestCreated, payload: %{})
    assert_receive {:child_emitted, child}, 5000

    assert child.correlation_id == parent.correlation_id
  end

  test "child event's causation_id is parent's id" do
    {:ok, parent} = Forja.emit(:propagation_test, EmitTestCreated, payload: %{})
    assert_receive {:child_emitted, child}, 5000

    assert child.causation_id == parent.id
  end

  test "context does not leak between events" do
    {:ok, _e1} = Forja.emit(:propagation_test, EmitTestCreated, payload: %{})
    assert_receive {:child_emitted, _}, 5000

    {:ok, e2} = Forja.emit(:propagation_test, EmitTestCreated, payload: %{})
    assert_receive {:child_emitted, child2}, 5000

    assert child2.correlation_id == e2.correlation_id
    assert child2.causation_id == e2.id
  end
end
