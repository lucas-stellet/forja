defmodule Forja.Handler do
  @moduledoc """
  Behaviour module for event handlers in Forja.

  Implement this behaviour to process events from the Oban processing pipeline.
  Each handler specifies which event types it subscribes to via `event_types/0`.

  ## Callbacks

  - `event_types/0` - Returns the list of event types this handler subscribes to,
    or `:all` to receive all events.
  - `handle_event/2` - Called for each event with the event struct and metadata.

  ## Failure Semantics

  Handlers must be **idempotent** — the same event may be delivered more than once
  in edge cases (e.g., network partitions, consumer crashes). Even if a handler
  returns an error, the event is considered processed and will not be retried.

  When a handler fails, the optional `on_failure/3` callback is invoked with the
  event, reason, and metadata. Use this to enqueue retries, emit compensating
  events, or alert. If `on_failure/3` is not implemented, the failure is logged
  and telemetry is emitted — no further action is taken.

  ## Example

      defmodule MyApp.UserEventHandler do
        @behaviour Forja.Handler

        @impl true
        def event_types, do: ["user.created", "user.updated"]

        @impl true
        def handle_event(%Forja.Event{} = event, meta) do
          # Process the event...
          :ok
        end
      end
  """

  @doc """
  Returns the list of event types this handler subscribes to, or `:all` for all events.

  ## Examples

      iex> MyHandler.event_types()
      ["user.created", "user.updated"]

      iex> WildcardHandler.event_types()
      :all
  """
  @callback event_types() :: [String.t()] | :all

  @doc """
  Handles a single event from the pipeline.

  The event is considered processed regardless of the return value. If you need to
  handle permanent failures, use `Forja.DeadLetter` to notify an error handler.

  ## Arguments

  - `event` - The `Forja.Event` struct being delivered
  - `meta` - Map containing delivery metadata:
    - `:forja_name` - The Forja instance atom
    - `:path` - Processing path (`:oban`, `:reconciliation`, `:inline`)
    - `:correlation_id` - UUID grouping all events in the same logical transaction
    - `:causation_id` - UUID of the event that caused this one (nil for root events)

    When you call `Forja.emit/3` inside a handler, `correlation_id` and `causation_id`
    are propagated automatically — you do NOT need to pass them manually.

  ## Examples

      iex> handler.handle_event(%Forja.Event{type: "user.created"}, %{})
      :ok

      iex> handler.handle_event(%Forja.Event{type: "user.created"}, %{deliveries: 3})
      {:error, :some_failure}
  """
  @callback handle_event(event :: Forja.Event.t(), meta :: map()) :: :ok | {:error, term()}

  @doc """
  Called when `handle_event/2` returns `{:error, reason}` or raises an exception.

  The `reason` is one of:
    - `{:error, term()}` — handler returned an error
    - `{:raised, Exception.t()}` — handler raised an exception

  Use this to enqueue retries, emit compensating events, or alert external systems.
  This callback is optional — if not implemented, failures are only logged and emitted
  as telemetry.

  ## Example

      @impl true
      def on_failure(%Forja.Event{} = event, {:error, :timeout}, _meta) do
        # Enqueue a retry as a dedicated Oban worker
        %{event_id: event.id}
        |> MyApp.Workers.RetryNotification.new()
        |> Oban.insert()
      end

      def on_failure(_event, _reason, _meta), do: :ok
  """
  @callback on_failure(event :: Forja.Event.t(), reason :: term(), meta :: map()) :: :ok | term()

  @optional_callbacks [on_failure: 3]
end
