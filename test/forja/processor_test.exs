defmodule Forja.ProcessorTest do
  use Forja.DataCase, async: false

  alias Forja.Config
  alias Forja.Event
  alias Forja.Processor
  alias Forja.Registry

  defmodule SuccessHandler do
    @moduledoc "Handler that always returns :ok."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["test:success"]

    @impl Forja.Handler
    def handle_event(event, _meta) do
      send(Process.whereis(:processor_test), {:handled, event.id})
      :ok
    end
  end

  defmodule ErrorHandler do
    @moduledoc "Handler that always returns an error."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["test:error"]

    @impl Forja.Handler
    def handle_event(_event, _meta) do
      {:error, :handler_failed}
    end
  end

  defmodule RaisingHandler do
    @moduledoc "Handler that always raises an exception."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["test:raise"]

    @impl Forja.Handler
    def handle_event(_event, _meta) do
      raise "boom"
    end
  end

  setup do
    Process.register(self(), :processor_test)

    config =
      Config.new(
        name: :processor_test,
        repo: Repo,
        pubsub: Phoenix.PubSub.Subscriber,
        handlers: [SuccessHandler, ErrorHandler, RaisingHandler]
      )

    Config.store(config)

    {table, catch_all} = Registry.build(config.handlers)
    Registry.store(:processor_test, table, catch_all)

    :ok
  end

  describe "process/3" do
    test "processes event and marks as processed" do
      event = insert_event!("test:success")

      assert :ok = Processor.process(:processor_test, event.id, :genstage)
      assert_receive {:handled, event_id}
      assert event_id == event.id

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "skips already processed events" do
      event = insert_event!("test:success", processed_at: DateTime.utc_now())

      assert :ok = Processor.process(:processor_test, event.id, :genstage)
      refute_receive {:handled, _}
    end

    test "returns ok for non-existent events" do
      assert :ok = Processor.process(:processor_test, Ecto.UUID.generate(), :genstage)
    end

    test "marks event as processed even when handler returns error" do
      event = insert_event!("test:error")

      assert :ok = Processor.process(:processor_test, event.id, :oban)

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end

    test "marks event as processed even when handler raises" do
      event = insert_event!("test:raise")

      assert :ok = Processor.process(:processor_test, event.id, :oban)

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.processed_at != nil
    end
  end

  defp insert_event!(type, attrs \\ []) do
    %Event{}
    |> Event.changeset(%{type: type, payload: %{}, meta: %{}})
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end
