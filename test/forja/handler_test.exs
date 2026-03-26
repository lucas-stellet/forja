defmodule Forja.HandlerTest do
  use ExUnit.Case, async: true

  alias Forja.Event

  # Implementation modules under test

  defmodule ValidHandler do
    @behaviour Forja.Handler

    @impl true
    def event_types, do: ["test:event"]

    @impl true
    def handle_event(%Event{}, _meta), do: :ok
  end

  defmodule AllEventsHandler do
    @behaviour Forja.Handler

    @impl true
    def event_types, do: :all

    @impl true
    def handle_event(%Event{}, _meta), do: :ok
  end

  describe "ValidHandler" do
    test "event_types returns specific event types" do
      assert ValidHandler.event_types() == ["test:event"]
    end

    test "handle_event returns :ok" do
      event = %Event{type: "test:event", payload: %{"key" => "value"}}
      meta = %{"source" => "test"}

      assert ValidHandler.handle_event(event, meta) == :ok
    end

    test "implements Forja.Handler behaviour" do
      # Verify callbacks are defined via function_exported?
      # The @behaviour annotation ensures compile-time verification
      assert function_exported?(ValidHandler, :event_types, 0)
      assert function_exported?(ValidHandler, :handle_event, 2)
    end
  end

  describe "AllEventsHandler" do
    test "event_types returns :all" do
      assert AllEventsHandler.event_types() == :all
    end

    test "handle_event returns :ok for any event type" do
      event = %Event{type: "arbitrary.type", payload: %{}}
      meta = %{}

      assert AllEventsHandler.handle_event(event, meta) == :ok
    end

    test "handles event with error tuple return" do
      defmodule ErrorHandler do
        @behaviour Forja.Handler

        @impl true
        def event_types, do: ["error:event"]

        @impl true
        def handle_event(%Event{}, _meta), do: {:error, :something_wrong}
      end

      event = %Event{type: "error:event"}
      assert ErrorHandler.handle_event(event, %{}) == {:error, :something_wrong}
    end
  end

  describe "behaviour callbacks" do
    test "Handler behaviour is properly defined" do
      # Verify the behaviour exists by checking that our modules implement it
      assert function_exported?(ValidHandler, :event_types, 0)
      assert function_exported?(ValidHandler, :handle_event, 2)
      assert function_exported?(AllEventsHandler, :event_types, 0)
      assert function_exported?(AllEventsHandler, :handle_event, 2)
    end
  end
end
