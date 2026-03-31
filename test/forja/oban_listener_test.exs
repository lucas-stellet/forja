defmodule Forja.ObanListenerTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.ObanListener
  alias Forja.Registry

  @pubsub Forja.ObanListenerTest.PubSub

  defmodule TestDeadLetterHandler do
    @moduledoc "Test dead letter handler for ObanListener."

    @behaviour Forja.DeadLetter

    @impl true
    def handle_dead_letter(event, reason) do
      send(Process.whereis(:oban_listener_test), {:dead_letter, event.id, reason})
      :ok
    end
  end

  setup do
    Process.register(self(), :oban_listener_test)
    start_supervised!({Phoenix.PubSub, name: @pubsub})

    config =
      Config.new(
        name: :oban_listener_test,
        repo: Repo,
        pubsub: @pubsub,
        handlers: [],
        dead_letter: TestDeadLetterHandler
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:oban_listener_test, table, catch_all)

    start_supervised!({ObanListener, name: :oban_listener_test})

    :ok
  end

  describe "dead letter detection via telemetry" do
    test "notifies dead letter handler when ProcessEventWorker is discarded" do
      event = insert_event!("oban_listener_test:event")
      listener_name = ObanListener.listener_name(:oban_listener_test)

      metadata = %{
        job: %Oban.Job{
          state: "discarded",
          worker: "Forja.Workers.ProcessEventWorker",
          args: %{"event_id" => event.id, "forja_name" => "oban_listener_test"}
        }
      }

      ObanListener.handle_oban_event(
        [:oban, :job, :stop],
        %{duration: 1_000},
        metadata,
        %{forja_name: :oban_listener_test, listener_name: listener_name}
      )

      assert_receive {:dead_letter, event_id, :oban_discarded}, 1_000
      assert event_id == event.id
    end

    test "ignores non-discarded jobs" do
      listener_name = ObanListener.listener_name(:oban_listener_test)

      metadata = %{
        job: %Oban.Job{
          state: "completed",
          worker: "Forja.Workers.ProcessEventWorker",
          args: %{"event_id" => "some-id", "forja_name" => "oban_listener_test"}
        }
      }

      ObanListener.handle_oban_event(
        [:oban, :job, :stop],
        %{duration: 1_000},
        metadata,
        %{forja_name: :oban_listener_test, listener_name: listener_name}
      )

      refute_receive {:dead_letter, _, _}
    end

    test "ignores jobs from other workers" do
      listener_name = ObanListener.listener_name(:oban_listener_test)

      metadata = %{
        job: %Oban.Job{
          state: "discarded",
          worker: "SomeOtherWorker",
          args: %{"event_id" => "some-id"}
        }
      }

      ObanListener.handle_oban_event(
        [:oban, :job, :stop],
        %{duration: 1_000},
        metadata,
        %{forja_name: :oban_listener_test, listener_name: listener_name}
      )

      refute_receive {:dead_letter, _, _}
    end
  end

  defp insert_event!(type) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Repo.insert!()
  end
end
