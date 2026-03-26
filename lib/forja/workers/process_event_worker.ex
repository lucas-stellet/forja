defmodule Forja.Workers.ProcessEventWorker do
  @moduledoc """
  Oban Worker for the guaranteed delivery path.

  Processes events via `Forja.Processor` with the same logic as the GenStage path.
  If GenStage already processed the event, the advisory lock or the `processed_at`
  check guarantee there is no reprocessing.

  ## Configuration

    * Queue: `:forja_events`
    * Unique: by `event_id`, period of 300 seconds
    * Max attempts: 3
  """

  use Oban.Worker,
    queue: :forja_events,
    unique: [keys: [:event_id], period: 300],
    max_attempts: 3

  @doc """
  Processes an event via `Forja.Processor` on the Oban guaranteed delivery path.

  Returns `:ok` on success or if the event was already processed or locked.
  Returns `{:error, reason}` to trigger Oban retry.
  Returns `{:cancel, message}` if the Forja instance name is unknown.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id, "forja_name" => forja_name}}) do
    name = String.to_existing_atom(forja_name)

    case Forja.Processor.process(name, event_id, :oban) do
      :ok -> :ok
      {:skipped, :locked} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:cancel, "Unknown Forja instance: #{forja_name}"}
  end
end
