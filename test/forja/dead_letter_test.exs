defmodule Forja.DeadLetterTest do
  use ExUnit.Case, async: true

  alias Forja.Event

  setup do
    # Register the current process for receiving dead letter notifications
    Process.register(self(), :dead_letter_test)
    :ok
  end

  defmodule TestDeadLetterHandler do
    @behaviour Forja.DeadLetter

    @impl true
    def handle_dead_letter(%Event{} = event, reason) do
      send(:dead_letter_test, {:dead_letter, event, reason})
      :ok
    end
  end

  describe "maybe_notify/3 with handler" do
    test "calls handler.handle_dead_letter with event and reason" do
      event = %Event{type: "test:failed", payload: %{"attempt" => 1}}
      reason = {:error, :timeout}

      # Call maybe_notify with a handler module
      result = Forja.DeadLetter.maybe_notify(TestDeadLetterHandler, event, reason)

      assert result == :ok

      # Verify the handler received the message
      assert_receive {:dead_letter, received_event, received_reason}
      assert received_event.type == "test:failed"
      assert received_reason == {:error, :timeout}
    end

    test "handler receives correct event data" do
      event = %Event{
        type: "user.payment",
        payload: %{"user_id" => 123, "amount" => 50},
        meta: %{"retry_count" => 3}
      }

      reason = {:error, :max_retries_exceeded}

      Forja.DeadLetter.maybe_notify(TestDeadLetterHandler, event, reason)

      assert_receive {:dead_letter, received_event, received_reason}
      assert received_event.type == "user.payment"
      assert received_event.payload == %{"user_id" => 123, "amount" => 50}
      assert received_reason == {:error, :max_retries_exceeded}
    end
  end

  describe "maybe_notify/3 with nil handler" do
    test "returns :ok without sending any message" do
      event = %Event{type: "test:event"}
      reason = {:error, :something}

      result = Forja.DeadLetter.maybe_notify(nil, event, reason)

      assert result == :ok
      refute_receive {:dead_letter, _, _}
    end

    test "nil handler is a no-op for any event" do
      event = %Event{type: "any:type", payload: %{"data" => 123}}
      reason = :failed

      # Multiple calls with nil should all be no-ops
      assert Forja.DeadLetter.maybe_notify(nil, event, reason) == :ok
      assert Forja.DeadLetter.maybe_notify(nil, event, :another_reason) == :ok
      assert Forja.DeadLetter.maybe_notify(nil, event, nil) == :ok

      # No messages should be sent to the registered process
      refute_receive {:dead_letter, _, _}, 50
    end
  end

  describe "TestDeadLetterHandler" do
    test "implements Forja.DeadLetter behaviour" do
      assert function_exported?(TestDeadLetterHandler, :handle_dead_letter, 2)
    end

    test "handle_dead_letter returns :ok" do
      event = %Event{type: "test"}
      reason = :failed

      assert TestDeadLetterHandler.handle_dead_letter(event, reason) == :ok
    end
  end
end
