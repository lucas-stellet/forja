defmodule Forja.Workers.ProcessEventWorkerTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.Registry
  alias Forja.Workers.ProcessEventWorker

  @pubsub Forja.Workers.ProcessEventWorkerTest.PubSub

  defmodule WorkerTestHandler do
    @moduledoc "Test handler for the Oban worker."

    @behaviour Forja.Handler

    @impl true
    def event_types, do: ["worker_test:event"]

    @impl true
    def handle_event(event, _meta) do
      send(Process.whereis(:worker_test), {:handled, event.id})
      :ok
    end
  end

  setup do
    Process.register(self(), :worker_test)
    start_supervised!({Phoenix.PubSub, name: @pubsub})

    config =
      Config.new(
        name: :worker_test,
        repo: Repo,
        pubsub: @pubsub,
        handlers: [WorkerTestHandler]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:worker_test, table, catch_all)

    :ok
  end

  describe "perform/1" do
    test "processes event via Processor" do
      event = insert_event!("worker_test:event")

      job = %Oban.Job{
        args: %{"event_id" => event.id, "forja_name" => "worker_test"}
      }

      assert :ok = ProcessEventWorker.perform(job)
      assert_receive {:handled, event_id}
      assert event_id == event.id

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "returns ok for already processed events" do
      event = insert_event!("worker_test:event", processed_at: DateTime.utc_now())

      job = %Oban.Job{
        args: %{"event_id" => event.id, "forja_name" => "worker_test"}
      }

      assert :ok = ProcessEventWorker.perform(job)
      refute_receive {:handled, _}
    end

    test "cancels job when forja_name is not a known atom" do
      job = %Oban.Job{
        args: %{
          "event_id" => Ecto.UUID.generate(),
          "forja_name" => "nonexistent_forja_instance_xyz"
        }
      }

      assert {:cancel, _reason} = ProcessEventWorker.perform(job)
    end
  end

  defp insert_event!(type, attrs \\ []) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end
