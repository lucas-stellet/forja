defmodule Forja.Workers.ReconciliationWorker do
  @moduledoc """
  Oban cron worker for reconciling unprocessed events.

  Periodically scans the `forja_events` table for events that remain
  unprocessed beyond a configurable threshold. For each stale event:

  1. Attempts processing via `Forja.Processor.process/3` with the
     `:reconciliation` path
  2. On success: the event is processed normally and
     `[:forja, :event, :reconciled]` telemetry is emitted
  3. On failure: increments `reconciliation_attempts` on the event
  4. When `reconciliation_attempts >= max_retries`: emits
     `[:forja, :event, :abandoned]` telemetry and invokes the
     configured `Forja.DeadLetter` callback

  ## Configuration

  Configured via the `:reconciliation` key in the Forja instance options:

      reconciliation: [
        enabled: true,
        interval_minutes: 60,
        threshold_minutes: 15,
        max_retries: 3
      ]

  ## Oban crontab setup

  Register this worker in the Oban configuration:

      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10, forja_events: 5, forja_reconciliation: 1],
        plugins: [
          {Oban.Plugins.Cron, crontab: [
            {"0 * * * *", Forja.Workers.ReconciliationWorker,
             args: %{forja_name: "my_app"}}
          ]}
        ]
  """

  use Oban.Worker,
    queue: :forja_reconciliation,
    unique: [period: 3600, keys: [:forja_name]],
    max_attempts: 1

  import Ecto.Query

  alias Forja.Config
  alias Forja.DeadLetter
  alias Forja.Event
  alias Forja.Telemetry

  @doc """
  Scans for stale unprocessed events and attempts to reconcile them.

  Events older than `threshold_minutes` with `processed_at` still `nil` and
  fewer than `max_retries` reconciliation attempts are picked up for processing.

  Returns `:ok` on completion, `{:ok, :disabled}` if reconciliation is disabled,
  or `{:cancel, message}` if the Forja instance name is unknown.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forja_name" => forja_name_str}}) do
    forja_name = String.to_existing_atom(forja_name_str)
    config = Config.get(forja_name)
    reconciliation = config.reconciliation

    if Keyword.get(reconciliation, :enabled, true) do
      threshold_minutes = Keyword.get(reconciliation, :threshold_minutes, 15)
      max_retries = Keyword.get(reconciliation, :max_retries, 3)
      cutoff = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

      stale_events =
        config.repo.all(
          from(e in Event,
            where: is_nil(e.processed_at),
            where: e.inserted_at < ^cutoff,
            where: e.reconciliation_attempts < ^max_retries,
            order_by: [asc: e.inserted_at]
          )
        )

      Enum.each(stale_events, fn event ->
        reconcile_event(config, forja_name, event, max_retries)
      end)

      :ok
    else
      {:ok, :disabled}
    end
  rescue
    ArgumentError -> {:cancel, "Unknown Forja instance: #{forja_name_str}"}
  end

  defp reconcile_event(config, forja_name, event, max_retries) do
    case Forja.Processor.process(forja_name, event.id, :reconciliation) do
      :ok ->
        Telemetry.emit_reconciled(forja_name, event.id)

      {:skipped, :locked} ->
        :ok

      {:error, _reason} ->
        updated_event =
          event
          |> Event.increment_reconciliation_changeset()
          |> config.repo.update!()

        if updated_event.reconciliation_attempts >= max_retries do
          Telemetry.emit_abandoned(forja_name, event.id, updated_event.reconciliation_attempts)
          DeadLetter.maybe_notify(config.dead_letter, updated_event, :reconciliation_exhausted)
        end
    end
  end
end
