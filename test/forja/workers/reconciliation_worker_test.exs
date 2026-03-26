defmodule Forja.Workers.ReconciliationWorkerTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Workers.ReconciliationWorker

  defmodule ReconciliationTestHandler do
    @moduledoc "Test handler for reconciliation."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["reconciliation_test:event"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:reconciliation_test), {:handled, event.id})
      :ok
    end
  end

  defmodule FailingHandler do
    @moduledoc "Handler that always fails for reconciliation tests."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["reconciliation_test:failing"]

    @impl Forja.Handler
    def handle_event(_event, _meta) do
      {:error, :always_fails}
    end
  end

  defmodule TestDeadLetterHandler do
    @moduledoc "Test dead letter handler for reconciliation."

    @behaviour Forja.DeadLetter

    @impl Forja.DeadLetter
    def handle_dead_letter(event, reason) do
      send(Process.whereis(:reconciliation_test), {:dead_letter, event.id, reason})
      :ok
    end
  end

  setup do
    Process.register(self(), :reconciliation_test)

    config =
      Config.new(
        name: :reconciliation_test,
        repo: Repo,
        pubsub: Forja.TestPubSub,
        handlers: [ReconciliationTestHandler, FailingHandler],
        dead_letter: TestDeadLetterHandler,
        reconciliation: [
          enabled: true,
          interval_minutes: 60,
          threshold_minutes: 0,
          max_retries: 2
        ]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:reconciliation_test, table, catch_all)

    :ok
  end

  describe "perform/1" do
    test "processes stale unprocessed events" do
      event = insert_stale_event!("reconciliation_test:event")

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      assert_receive {:handled, event_id}
      assert event_id == event.id

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "ignores recently inserted events within threshold" do
      config =
        Config.new(
          name: :reconciliation_threshold_test,
          repo: Repo,
          pubsub: Forja.TestPubSub,
          handlers: [ReconciliationTestHandler],
          reconciliation: [
            enabled: true,
            interval_minutes: 60,
            threshold_minutes: 60,
            max_retries: 3
          ]
        )

      Config.store(config)

      {table, catch_all} = Registry.build(config.handlers)
      Registry.store(:reconciliation_threshold_test, table, catch_all)

      _event = insert_event!("reconciliation_test:event")

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_threshold_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      refute_receive {:handled, _}
    end

    test "processes event even when handler returns error (marks as processed)" do
      event = insert_stale_event!("reconciliation_test:failing")

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      reloaded = Repo.get!(Event, event.id)
      # Processor always marks as processed, even when handlers fail
      assert reloaded.processed_at != nil
      assert reloaded.reconciliation_attempts == 0
    end

    test "returns disabled when reconciliation is disabled" do
      config =
        Config.new(
          name: :reconciliation_disabled_test,
          repo: Repo,
          pubsub: Forja.TestPubSub,
          handlers: [],
          reconciliation: [enabled: false]
        )

      Config.store(config)

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_disabled_test"}}
      assert {:ok, :disabled} = ReconciliationWorker.perform(job)
    end

    test "skips events that already reached max retries" do
      _event = insert_stale_event!("reconciliation_test:failing", reconciliation_attempts: 2)

      job = %Oban.Job{args: %{"forja_name" => "reconciliation_test"}}
      assert :ok = ReconciliationWorker.perform(job)

      refute_receive {:dead_letter, _, _}
    end

    test "cancels job when forja_name is not a known atom" do
      job = %Oban.Job{args: %{"forja_name" => "nonexistent_forja_instance_xyz"}}

      assert {:cancel, _reason} = ReconciliationWorker.perform(job)
    end
  end

  defp insert_event!(type) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Repo.insert!()
  end

  defp insert_stale_event!(type, attrs \\ []) do
    stale_time = DateTime.add(DateTime.utc_now(), -3600, :second)

    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Ecto.Changeset.change([{:inserted_at, stale_time} | attrs])
    |> Repo.insert!()
  end
end
