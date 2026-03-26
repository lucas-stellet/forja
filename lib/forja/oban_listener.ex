defmodule Forja.ObanListener do
  @moduledoc """
  Listens for Oban telemetry events to detect discarded `ProcessEventWorker` jobs.

  When a `ProcessEventWorker` job is discarded by Oban (all attempts exhausted),
  this module emits a `[:forja, :event, :dead_letter]` telemetry event and
  invokes the configured `Forja.DeadLetter` callback, if any.

  Started as part of the Forja supervision tree.

  ## Implementation note

  The telemetry callback looks up the listener process by its registered name
  at call time rather than capturing the PID at attach time. This is critical
  for correctness: if the GenServer restarts, a stale captured PID would point
  to a dead process. Using the registered name ensures the message always
  reaches the current live process.
  """

  use GenServer

  alias Forja.Config
  alias Forja.DeadLetter
  alias Forja.Event
  alias Forja.Telemetry

  @doc """
  Starts the ObanListener process.

  ## Options

    * `:name` - Forja instance name (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: listener_name(name))
  end

  @doc """
  Returns the registered name of the listener for a Forja instance.
  """
  @spec listener_name(atom()) :: atom()
  def listener_name(name) do
    Module.concat([Forja, ObanListener, name])
  end

  @impl GenServer
  def init(opts) do
    forja_name = Keyword.fetch!(opts, :name)
    handler_id = "forja-oban-listener-#{forja_name}"

    :telemetry.attach(
      handler_id,
      [:oban, :job, :stop],
      &__MODULE__.handle_oban_event/4,
      %{forja_name: forja_name, listener_name: listener_name(forja_name)}
    )

    {:ok, %{forja_name: forja_name, handler_id: handler_id}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @doc """
  Telemetry handler callback for Oban job stop events.

  Filters for discarded `Forja.Workers.ProcessEventWorker` jobs and sends
  a message to the `ObanListener` GenServer process for asynchronous
  dead letter processing.

  Telemetry handlers must be non-blocking. All I/O (DB lookup, dead letter
  callback) is delegated to the GenServer via `send/2` so that the Oban
  worker process is not held up.

  The listener process is resolved by its registered name at call time to
  avoid stale PID references after a GenServer restart.
  """
  @spec handle_oban_event([atom()], map(), map(), map()) :: :ok
  def handle_oban_event(
        [:oban, :job, :stop],
        _measurements,
        %{job: %Oban.Job{state: "discarded", worker: worker, args: %{"event_id" => event_id}}},
        %{forja_name: forja_name, listener_name: listener_name}
      )
      when worker == "Forja.Workers.ProcessEventWorker" do
    case Process.whereis(listener_name) do
      nil -> :ok
      pid -> send(pid, {:dead_letter_check, forja_name, event_id})
    end

    :ok
  end

  def handle_oban_event(_event_name, _measurements, _metadata, _config), do: :ok

  @impl GenServer
  def handle_info({:dead_letter_check, forja_name, event_id}, state) do
    config = Config.get(forja_name)

    case config.repo.get(Event, event_id) do
      nil ->
        :ok

      %Event{} = event ->
        Telemetry.emit_dead_letter(forja_name, event_id, :oban_discarded)
        DeadLetter.maybe_notify(config.dead_letter, event, :oban_discarded)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
