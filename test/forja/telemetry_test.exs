defmodule Forja.TelemetryTest do
  use ExUnit.Case, async: true

  alias Forja.Telemetry

  setup do
    ref = make_ref()
    test_pid = self()

    handler_id = "test-handler-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      [
        [:forja, :event, :emitted],
        [:forja, :event, :processed],
        [:forja, :event, :failed],
        [:forja, :event, :skipped],
        [:forja, :event, :dead_letter],
        [:forja, :event, :abandoned],
        [:forja, :event, :reconciled],
        [:forja, :event, :deduplicated],
        [:forja, :producer, :buffer_size]
      ],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "emit_emitted/3 sends telemetry event" do
    Telemetry.emit_emitted(:test, "order:created", "orders")

    assert_receive {:telemetry, [:forja, :event, :emitted], %{count: 1},
                    %{name: :test, type: "order:created", source: "orders"}}
  end

  test "emit_processed/5 sends telemetry event with duration" do
    Telemetry.emit_processed(:test, "order:created", FakeHandler, :genstage, 1_000)

    assert_receive {:telemetry, [:forja, :event, :processed], %{duration: 1_000},
                    %{name: :test, type: "order:created", handler: FakeHandler, path: :genstage}}
  end

  test "emit_failed/5 sends telemetry event with reason" do
    Telemetry.emit_failed(:test, "order:created", FakeHandler, :oban, :timeout)

    assert_receive {:telemetry, [:forja, :event, :failed], %{count: 1},
                    %{name: :test, type: "order:created", handler: FakeHandler, path: :oban, reason: :timeout}}
  end

  test "emit_skipped/3 sends telemetry event" do
    Telemetry.emit_skipped(:test, "event-uuid-123", :genstage)

    assert_receive {:telemetry, [:forja, :event, :skipped], %{count: 1},
                    %{name: :test, event_id: "event-uuid-123", path: :genstage}}
  end

  test "emit_buffer_size/2 sends telemetry event" do
    Telemetry.emit_buffer_size(:test, 42)

    assert_receive {:telemetry, [:forja, :producer, :buffer_size], %{size: 42},
                    %{name: :test}}
  end

  test "emit_dead_letter/3 sends telemetry event" do
    Telemetry.emit_dead_letter(:test, "event-uuid-dead", :max_attempts_reached)

    assert_receive {:telemetry, [:forja, :event, :dead_letter], %{count: 1},
                    %{name: :test, event_id: "event-uuid-dead", reason: :max_attempts_reached}}
  end

  test "emit_abandoned/3 sends telemetry event" do
    Telemetry.emit_abandoned(:test, "event-uuid-abandoned", 3)

    assert_receive {:telemetry, [:forja, :event, :abandoned], %{count: 1},
                    %{name: :test, event_id: "event-uuid-abandoned", reconciliation_attempts: 3}}
  end

  test "emit_reconciled/2 sends telemetry event" do
    Telemetry.emit_reconciled(:test, "event-uuid-reconciled")

    assert_receive {:telemetry, [:forja, :event, :reconciled], %{count: 1},
                    %{name: :test, event_id: "event-uuid-reconciled"}}
  end

  test "emit_deduplicated/3 sends telemetry event" do
    Telemetry.emit_deduplicated(:test, "my-idempotency-key", "existing-event-id")

    assert_receive {:telemetry, [:forja, :event, :deduplicated], %{count: 1},
                    %{name: :test, idempotency_key: "my-idempotency-key", existing_event_id: "existing-event-id"}}
  end
end
