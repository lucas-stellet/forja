defmodule Forja.TestConsumer do
  @moduledoc """
  GenStage test consumer that sends messages to the test process.
  """

  use GenStage

  @impl GenStage
  def init(%{test_pid: test_pid, subscribe_to: producer}) do
    {:consumer, %{test_pid: test_pid}, subscribe_to: [{producer, max_demand: 1}]}
  end

  @impl GenStage
  def handle_events(events, _from, state) do
    Enum.each(events, fn event_id ->
      send(state.test_pid, {:consumed, event_id})
    end)

    {:noreply, [], state}
  end
end
