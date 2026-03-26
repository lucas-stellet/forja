defmodule Forja.DeadLetter do
  @moduledoc """
  Behaviour module for handling dead letters (events that failed permanent processing).

  Use this to capture events that could not be processed after all retries,
  log them for investigation, send alerts, or store them for later analysis.

  ## Configuration

  Set the `dead_letter` field in `Forja.Config` to your handler module:

      Forja.Config.new(
        name: :my_forja,
        repo: MyApp.Repo,
        pubsub: MyApp.PubSub,
        dead_letter: MyApp.DeadLetterHandler
      )

  ## Example Implementation

      defmodule MyApp.DeadLetterHandler do
        @behaviour Forja.DeadLetter

        @impl true
        def handle_dead_letter(%Forja.Event{} = event, reason) do
          Logger.error("Event failed after retries",
            event_id: event.id,
            event_type: event.type,
            reason: reason
          )

          # Optionally store to a dead letter table, send to Sentry, etc.
          :ok
        end
      end
  """

  @doc """
  Called when an event has failed processing after all retries.

  ## Arguments

  - `event` - The `Forja.Event` struct that could not be processed
  - `reason` - The reason for failure (e.g., `{:error, :max_retries_exceeded}`)

  ## Examples

      iex> handler.handle_dead_letter(event, {:error, :timeout})
      :ok
  """
  @callback handle_dead_letter(event :: Forja.Event.t(), reason :: term()) :: :ok

  @doc """
  Notifies the configured dead letter handler, if one is set.

  If `handler` is `nil`, this is a no-op and returns `:ok`.

  ## Examples

      iex> Forja.DeadLetter.maybe_notify(nil, event, reason)
      :ok

      iex> Forja.DeadLetter.maybe_notify(MyHandler, event, reason)
      :ok
  """
  @spec maybe_notify(handler :: module() | nil, event :: Forja.Event.t(), reason :: term()) :: :ok
  def maybe_notify(nil, _event, _reason) do
    :ok
  end

  def maybe_notify(handler, event, reason) do
    handler.handle_dead_letter(event, reason)
  end
end
