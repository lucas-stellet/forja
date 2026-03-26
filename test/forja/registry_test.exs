defmodule Forja.RegistryTest do
  use ExUnit.Case, async: true

  alias Forja.Registry

  defmodule OrderHandler do
    @moduledoc "Test handler for orders."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["order:created", "order:cancelled"]

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  defmodule NotificationHandler do
    @moduledoc "Test handler for notifications."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: ["order:created"]

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  defmodule AuditHandler do
    @moduledoc "Test handler that processes all events."

    @behaviour Forja.Handler

    @impl Forja.Handler
    def event_types, do: :all

    @impl Forja.Handler
    def handle_event(_event, _meta), do: :ok
  end

  describe "build/1" do
    test "builds dispatch table from typed handlers" do
      {table, catch_all} = Registry.build([OrderHandler, NotificationHandler])

      assert catch_all == []
      assert table["order:created"] == [OrderHandler, NotificationHandler]
      assert table["order:cancelled"] == [OrderHandler]
    end

    test "separates catch-all handlers" do
      {table, catch_all} = Registry.build([OrderHandler, AuditHandler])

      assert catch_all == [AuditHandler]
      assert table["order:created"] == [OrderHandler]
      refute Map.has_key?(table, :all)
    end

    test "returns empty table for empty handlers list" do
      {table, catch_all} = Registry.build([])

      assert table == %{}
      assert catch_all == []
    end
  end

  describe "store/3 and handlers_for/2" do
    test "stores and retrieves handlers by event type" do
      {table, catch_all} = Registry.build([OrderHandler, NotificationHandler])
      Registry.store(:registry_test, table, catch_all)

      assert Registry.handlers_for(:registry_test, "order:created") == [
               OrderHandler,
               NotificationHandler
             ]

      assert Registry.handlers_for(:registry_test, "order:cancelled") == [OrderHandler]
    end

    test "includes catch-all handlers in results" do
      {table, catch_all} = Registry.build([OrderHandler, AuditHandler])
      Registry.store(:registry_catch_all_test, table, catch_all)

      handlers = Registry.handlers_for(:registry_catch_all_test, "order:created")
      assert handlers == [OrderHandler, AuditHandler]
    end

    test "returns only catch-all handlers for unknown event types" do
      {table, catch_all} = Registry.build([OrderHandler, AuditHandler])
      Registry.store(:registry_unknown_test, table, catch_all)

      handlers = Registry.handlers_for(:registry_unknown_test, "unknown:event")
      assert handlers == [AuditHandler]
    end

    test "returns empty list when no handlers match and no catch-all" do
      {table, catch_all} = Registry.build([OrderHandler])
      Registry.store(:registry_empty_test, table, catch_all)

      assert Registry.handlers_for(:registry_empty_test, "unknown:event") == []
    end
  end
end
