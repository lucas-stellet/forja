defmodule Forja.Processor do
  @moduledoc """
  Functional core of event processing.

  Orchestrates the flow:
  1. Loads the event from the database
  2. Checks if it has already been processed (`processed_at`)
  3. Dispatches to handlers via Registry
  4. Marks as processed
  5. Broadcasts via PubSub

  Called by the Oban worker and the reconciliation worker.
  This module has no GenServer state -- it operates as a stateless service module.
  """

  require Logger

  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Telemetry

  @spec process(atom(), String.t(), atom()) :: :ok | {:error, term()}
  def process(name, event_id, path) do
    config = Config.get(name)

    case config.repo.get(Event, event_id) do
      nil ->
        Logger.warning("Forja: event #{event_id} not found in database", domain: [:forja])
        :ok

      %Event{processed_at: processed_at} when not is_nil(processed_at) ->
        :ok

      %Event{} = event ->
        dispatch_to_handlers(config, name, event, path)

        case mark_processed(config, event) do
          {:ok, updated_event} ->
            safe_broadcast(config, updated_event, :forja_event_processed)
            :ok

          {:error, changeset} ->
            Logger.error(
              "Forja: failed to mark event #{event_id} as processed: #{inspect(changeset.errors)}",
              domain: [:forja]
            )

            {:error, changeset}
        end
    end
  end

  defp dispatch_to_handlers(_config, name, event, path) do
    handlers = Registry.handlers_for(name, event.type)

    Process.put(:forja_correlation_id, event.correlation_id)
    Process.put(:forja_causation_event_id, event.id)

    Enum.each(handlers, fn handler ->
      start_time = System.monotonic_time()

      meta = %{
        forja_name: name,
        path: path,
        correlation_id: event.correlation_id,
        causation_id: event.id
      }

      try do
        case handler.handle_event(event, meta) do
          :ok ->
            duration = System.monotonic_time() - start_time

            Telemetry.emit_processed(name, %{
              type: event.type,
              handler: handler,
              path: path,
              duration: duration
            })

          {:error, reason} ->
            Logger.error(
              "Forja: handler #{inspect(handler)} returned error for event #{event.id}: #{inspect(reason)}",
              domain: [:forja]
            )

            Telemetry.emit_failed(name, %{
              type: event.type,
              handler: handler,
              path: path,
              reason: reason
            })

            maybe_on_failure(handler, event, {:error, reason}, meta)
        end
      rescue
        exception ->
          Logger.error(
            "Forja: handler #{inspect(handler)} raised for event #{event.id}: #{Exception.message(exception)}",
            domain: [:forja]
          )

          Telemetry.emit_failed(name, %{
            type: event.type,
            handler: handler,
            path: path,
            reason: exception
          })

          maybe_on_failure(handler, event, {:raised, exception}, meta)
      end
    end)

    :ok
  after
    Process.delete(:forja_correlation_id)
    Process.delete(:forja_causation_event_id)
  end

  defp mark_processed(config, event) do
    event
    |> Event.mark_processed_changeset()
    |> config.repo.update()
  end

  defp safe_broadcast(config, event, tag) do
    topic = "#{config.event_topic_prefix}:events"
    Phoenix.PubSub.broadcast(config.pubsub, topic, {tag, event})
  rescue
    error ->
      Logger.warning("Forja: PubSub broadcast failed: #{inspect(error)}", domain: [:forja])
      :ok
  end

  defp maybe_on_failure(handler, event, reason, meta) do
    if function_exported?(handler, :on_failure, 3) do
      try do
        handler.on_failure(event, reason, meta)
      rescue
        exception ->
          Logger.error(
            "Forja: on_failure/3 raised in #{inspect(handler)} for event #{event.id}: #{Exception.message(exception)}",
            domain: [:forja]
          )
      end
    end
  end
end
