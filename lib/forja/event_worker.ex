defmodule Forja.EventWorker do
  @moduledoc """
  Transient Task that processes a single event via `Forja.Processor`.

  Spawned by `Forja.EventConsumer` (ConsumerSupervisor) for each event
  received from the producer. Dies after processing, releasing demand
  for the next event.
  """

  @doc """
  Starts a Task that processes the event identified by `event_id`.
  """
  @spec start_link(atom(), String.t()) :: {:ok, pid()}
  def start_link(name, event_id) do
    Task.start_link(fn ->
      Forja.Processor.process(name, event_id, :genstage)
    end)
  end
end
