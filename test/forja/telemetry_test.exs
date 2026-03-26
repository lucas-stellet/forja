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

  test "emit_emitted/4 sends telemetry event" do
    Telemetry.emit_emitted(:test, "order:created", "orders")

    assert_receive {:telemetry, [:forja, :event, :emitted], %{count: 1},
                    %{name: :test, type: "order:created", source: "orders"}}
  end

  test "emit_emitted/4 includes payload when provided" do
    Telemetry.emit_emitted(:test, "order:created", "orders", %{"id" => 1})

    assert_receive {:telemetry, [:forja, :event, :emitted], %{count: 1},
                    %{name: :test, type: "order:created", payload: %{"id" => 1}}}
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

defmodule Forja.Telemetry.DefaultLoggerTest do
  use ExUnit.Case, async: false

  require Logger
  import ExUnit.CaptureLog

  alias Forja.Telemetry

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Telemetry.detach_default_logger()
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  describe "attach_default_logger/1" do
    test "logs emitted events at info level by default" do
      Telemetry.attach_default_logger()

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders")
        end)

      assert log =~ "Event emitted"
      assert log =~ "order:created"
      assert log =~ "[info]"
    end

    test "logs processed events with duration" do
      Telemetry.attach_default_logger()

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_processed(:my_app, "order:created", MyHandler, :oban, 5_000_000)
        end)

      assert log =~ "Event processed"
      assert log =~ "MyHandler"
      assert log =~ "oban"
      assert log =~ "duration_us"
    end

    test "logs failed events at warning level" do
      Telemetry.attach_default_logger()

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_failed(:my_app, "order:created", MyHandler, :oban, :timeout)
        end)

      assert log =~ "Handler failed"
      assert log =~ "[warning]"
      assert log =~ ":timeout"
    end

    test "logs dead_letter events at error level" do
      Telemetry.attach_default_logger()

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_dead_letter(:my_app, "event-123", :max_attempts)
        end)

      assert log =~ "Event dead-lettered"
      assert log =~ "[error]"
    end

    test "logs abandoned events at error level" do
      Telemetry.attach_default_logger()

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_abandoned(:my_app, "event-123", 3)
        end)

      assert log =~ "Event abandoned"
      assert log =~ "[error]"
      assert log =~ "reconciliation_attempts"
    end
  end

  describe "level tiers" do
    test "level: :debug includes skipped and deduplicated events" do
      Telemetry.attach_default_logger(level: :debug)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_skipped(:my_app, "event-456", :genstage)
          Telemetry.emit_deduplicated(:my_app, "key-1", "event-789")
        end)

      assert log =~ "Event skipped"
      assert log =~ "Event deduplicated"
    end

    test "level: :info does NOT include skipped or deduplicated" do
      Telemetry.attach_default_logger(level: :info)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_skipped(:my_app, "event-456", :genstage)
          Telemetry.emit_deduplicated(:my_app, "key-1", "event-789")
        end)

      refute log =~ "Event skipped"
      refute log =~ "Event deduplicated"
    end

    test "level: :warning does NOT include emitted or processed" do
      Telemetry.attach_default_logger(level: :warning)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders")
          Telemetry.emit_processed(:my_app, "order:created", MyHandler, :oban, 1_000)
          Telemetry.emit_failed(:my_app, "order:created", MyHandler, :oban, :timeout)
        end)

      refute log =~ "Event emitted"
      refute log =~ "Event processed"
      assert log =~ "Handler failed"
    end

    test "level: :error only includes dead_letter and abandoned" do
      Telemetry.attach_default_logger(level: :error)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders")
          Telemetry.emit_failed(:my_app, "order:created", MyHandler, :oban, :timeout)
          Telemetry.emit_dead_letter(:my_app, "event-123", :max_attempts)
        end)

      refute log =~ "Event emitted"
      refute log =~ "Handler failed"
      assert log =~ "Event dead-lettered"
    end
  end

  describe "include_payload option" do
    test "includes payload when include_payload: true" do
      Telemetry.attach_default_logger(include_payload: true)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders", %{"order_id" => 42})
        end)

      assert log =~ "order_id"
      assert log =~ "42"
    end

    test "excludes payload by default" do
      Telemetry.attach_default_logger()

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders", %{"order_id" => 42})
        end)

      refute log =~ "order_id"
    end
  end

  describe "encode option" do
    test "produces JSON when encode: true" do
      Telemetry.attach_default_logger(encode: true)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders")
        end)

      # Extract the JSON portion from the log line
      assert log =~ "\"event\":\"event:emitted\""
      assert log =~ "\"source\":\"forja\""
    end
  end

  describe "events filter" do
    test "explicit events list overrides level tier" do
      Telemetry.attach_default_logger(events: [:emitted])

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders")
          Telemetry.emit_processed(:my_app, "order:created", MyHandler, :oban, 1_000)
        end)

      assert log =~ "Event emitted"
      refute log =~ "Event processed"
    end
  end

  describe "detach_default_logger/0" do
    test "stops logging after detach" do
      Telemetry.attach_default_logger()
      Telemetry.detach_default_logger()

      log =
        capture_log([level: :debug], fn ->
          Telemetry.emit_emitted(:my_app, "order:created", "orders")
        end)

      refute log =~ "Event emitted"
    end

    test "returns error when not attached" do
      assert {:error, :not_found} = Telemetry.detach_default_logger()
    end
  end

  describe "double attach" do
    test "returns error on second attach" do
      assert :ok = Telemetry.attach_default_logger()
      assert {:error, :already_exists} = Telemetry.attach_default_logger()
    end
  end
end
