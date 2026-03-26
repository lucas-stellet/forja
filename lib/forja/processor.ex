defmodule Forja.Processor do
  @moduledoc """
  Functional core of exactly-once processing.

  Orchestrates the flow:
  1. Acquires an advisory lock for the event
  2. Loads the event from the database (if necessary)
  3. Checks if it has already been processed (`processed_at`)
  4. Dispatches to handlers via Registry
  5. Marks as processed

  This module is called by both the GenStage consumer and the Oban worker.
  It has no state -- it is a pure functional module.
  """

  require Logger

  alias Forja.AdvisoryLock
  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Telemetry

  @doc """
  Processes an event identified by `event_id`.

  The `path` indicates the processing origin (`:genstage`, `:oban`,
  `:reconciliation`, or `:inline`) and is used for telemetry.

  ## Return values

    * `:ok` - Event processed successfully (or already processed)
    * `{:skipped, :locked}` - Lock was already held by another path
    * `{:error, reason}` - Error during processing
  """
  @spec process(atom(), String.t(), atom()) :: :ok | {:skipped, :locked} | {:error, term()}
  def process(name, event_id, path) do
    config = Config.get(name)
    lock_result = AdvisoryLock.with_lock(config.repo, {:forja_event, event_id}, fn ->
      do_process(config, name, event_id, path)
    end)

    case lock_result do
      {:ok, :ok} ->
        :ok

      {:ok, {:already_processed, _}} ->
        :ok

      {:skipped, :locked} ->
        Telemetry.emit_skipped(name, event_id, path)
        {:skipped, :locked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_process(config, name, event_id, path) do
    case config.repo.get(Event, event_id) do
      nil ->
        Logger.warning("Forja: event #{event_id} not found in database")
        :ok

      %Event{processed_at: processed_at} when not is_nil(processed_at) ->
        {:already_processed, event_id}

      %Event{} = event ->
        dispatch_to_handlers(config, name, event, path)
        mark_processed(config, event)
        :ok
    end
  end

  defp dispatch_to_handlers(_config, name, event, path) do
    handlers = Registry.handlers_for(name, event.type)

    errors =
      Enum.flat_map(handlers, fn handler ->
        start_time = System.monotonic_time()

        try do
          meta = %{forja_name: name, path: path}

          case handler.handle_event(event, meta) do
            :ok ->
              duration = System.monotonic_time() - start_time
              Telemetry.emit_processed(name, event.type, handler, path, duration)
              []

            {:error, reason} ->
              Logger.error(
                "Forja: handler #{inspect(handler)} returned error for event #{event.id}: #{inspect(reason)}"
              )

              Telemetry.emit_failed(name, event.type, handler, path, reason)
              [{:error, reason}]
          end
        rescue
          exception ->
            Logger.error(
              "Forja: handler #{inspect(handler)} raised for event #{event.id}: #{Exception.message(exception)}"
            )

            Telemetry.emit_failed(name, event.type, handler, path, exception)
            [{:error, exception}]
        end
      end)

    case errors do
      [] -> :ok
      [{:error, reason} | _] -> {:error, reason}
    end
  end

  defp mark_processed(config, event) do
    event
    |> Event.mark_processed_changeset()
    |> config.repo.update!()
  end
end
