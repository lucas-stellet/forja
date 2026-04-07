defmodule Forja.EventSchemaEmitTest do
  use Forja.DataCase, async: false

  alias Forja.Event

  defmodule ValidTestEvent do
    use Forja.Event.Schema, event_type: "schema_test:valid", schema_version: 2

    payload do
      field(:user_id, Zoi.string())
      field(:amount_cents, Zoi.integer() |> Zoi.positive())
      field(:currency, Zoi.string() |> Zoi.default("USD"), required: false)
    end
  end

  defmodule InvalidTestEvent do
    use Forja.Event.Schema, event_type: "schema_test:invalid"

    payload do
      field(:user_id, Zoi.string())
      field(:amount_cents, Zoi.integer() |> Zoi.positive())
    end
  end

  defmodule MissingRequiredEvent do
    use Forja.Event.Schema, event_type: "schema_test:missing_required"

    payload do
      field(:user_id, Zoi.string())
      field(:email, Zoi.string(), required: true)
    end
  end

  defmodule EmittableEvent do
    use Forja.Event.Schema,
      event_type: "schema_test:emittable",
      forja: :schema_emit_test,
      source: "test_source",
      queue: :payments

    payload do
      field(:order_id, Zoi.string())
      field(:amount, Zoi.integer() |> Zoi.positive())
    end

    def idempotency_key(payload) do
      "emittable:#{payload["order_id"]}"
    end
  end

  defmodule EmittableNoIdempotencyEvent do
    use Forja.Event.Schema,
      event_type: "schema_test:emittable_no_idemp",
      forja: :schema_emit_test

    payload do
      field(:name, Zoi.string())
    end
  end

  defmodule NonEmittableEvent do
    use Forja.Event.Schema, event_type: "schema_test:non_emittable"

    payload do
      field(:name, Zoi.string())
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Forja.SchemaEmitTestPubSub})

    start_supervised!(
      {Oban, name: Forja.SchemaEmitTestOban, repo: Repo, queues: false, testing: :inline}
    )

    start_supervised!(
      {Forja,
       name: :schema_emit_test,
       repo: Repo,
       pubsub: Forja.SchemaEmitTestPubSub,
       oban_name: Forja.SchemaEmitTestOban,
       handlers: []}
    )

    :ok
  end

  describe "emit/3 with schema module" do
    test "valid payload -> persisted with correct type, schema_version, string-keyed payload" do
      assert {:ok, event} =
               Forja.emit(:schema_emit_test, ValidTestEvent,
                 payload: %{user_id: "u123", amount_cents: 1000}
               )

      assert event.type == "schema_test:valid"
      assert event.schema_version == 2
      assert event.payload == %{"user_id" => "u123", "amount_cents" => 1000}
      refute Map.has_key?(event.payload, "currency")

      persisted = Repo.get!(Event, event.id)
      assert persisted.type == "schema_test:valid"
      assert persisted.schema_version == 2
      assert persisted.payload == %{"user_id" => "u123", "amount_cents" => 1000}
    end

    test "invalid payload (wrong type) -> error" do
      result =
        Forja.emit(:schema_emit_test, InvalidTestEvent,
          payload: %{user_id: "u123", amount_cents: "not_an_integer"}
        )

      assert {:error, %Forja.ValidationError{}} = result
    end

    test "missing required field -> error" do
      result =
        Forja.emit(:schema_emit_test, MissingRequiredEvent, payload: %{user_id: "u123"})

      assert {:error, %Forja.ValidationError{}} = result
    end

    test "schema_version is taken from the schema module" do
      assert {:ok, event} =
               Forja.emit(:schema_emit_test, ValidTestEvent,
                 payload: %{user_id: "u123", amount_cents: 500}
               )

      assert event.schema_version == 2
    end
  end

  describe "emit_multi/4 with schema module" do
    test "valid payload via static payload -> persisted" do
      multi =
        Ecto.Multi.new()
        |> Forja.emit_multi(:schema_emit_test, ValidTestEvent,
          payload: %{user_id: "u456", amount_cents: 2500}
        )

      assert {:ok, result} = Repo.transaction(multi)
      event = result[:"forja_event_schema_test:valid"]
      assert event.type == "schema_test:valid"
      assert event.schema_version == 2
      assert event.payload == %{"user_id" => "u456", "amount_cents" => 2500}
      refute Map.has_key?(event.payload, "currency")
    end

    test "valid payload via payload_fn -> persisted" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:setup, fn _repo, _changes ->
          {:ok, %{user_id: "u789", amount_cents: 3000}}
        end)
        |> Forja.emit_multi(:schema_emit_test, ValidTestEvent,
          payload_fn: fn %{setup: setup} ->
            %{user_id: setup.user_id, amount_cents: setup.amount_cents}
          end
        )

      assert {:ok, result} = Repo.transaction(multi)
      event = result[:"forja_event_schema_test:valid"]
      assert event.type == "schema_test:valid"
      assert event.schema_version == 2
      assert event.payload == %{"user_id" => "u789", "amount_cents" => 3000}
      refute Map.has_key?(event.payload, "currency")
    end

    test "invalid payload -> Multi rolls back" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:setup, fn _repo, _changes ->
          {:ok, %{bad: "data"}}
        end)
        |> Forja.emit_multi(:schema_emit_test, ValidTestEvent,
          payload_fn: fn %{setup: _setup} ->
            %{user_id: "u123", amount_cents: "not_an_integer"}
          end
        )

      assert {:error, :"forja_event_schema_test:valid", %Forja.ValidationError{}, _changes} =
               Repo.transaction(multi)
    end
  end

  describe "telemetry on validation failure" do
    test "emits [:forja, :event, :validation_failed] on invalid payload" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-validation-failed-#{inspect(ref)}",
        [:forja, :event, :validation_failed],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:validation_failed, metadata})
        end,
        nil
      )

      assert {:error, %Forja.ValidationError{errors: errors}} =
               Forja.emit(:schema_emit_test, ValidTestEvent,
                 payload: %{user_id: "u123", amount_cents: -1}
               )

      assert is_list(errors)
      assert_receive {:validation_failed, %{name: :schema_emit_test, errors: telemetry_errors}}
      assert is_list(telemetry_errors)
      assert hd(telemetry_errors) |> Map.has_key?(:field)

      :telemetry.detach("test-validation-failed-#{inspect(ref)}")
    end
  end

  describe "Schema.emit/1,2" do
    test "emits event with schema defaults" do
      assert {:ok, event} = EmittableEvent.emit(%{order_id: "o1", amount: 100})

      assert event.type == "schema_test:emittable"
      assert event.payload == %{"order_id" => "o1", "amount" => 100}
      assert event.source == "test_source"
      assert event.idempotency_key == "emittable:o1"
    end

    test "source can be overridden" do
      assert {:ok, event} =
               EmittableEvent.emit(%{order_id: "o2", amount: 200}, source: "manual")

      assert event.source == "manual"
      assert event.idempotency_key == "emittable:o2"
    end

    test "idempotency_key can be overridden" do
      assert {:ok, event} =
               EmittableEvent.emit(%{order_id: "o3", amount: 300},
                 idempotency_key: "custom-key"
               )

      assert event.idempotency_key == "custom-key"
    end

    test "correlation_id and causation_id can be passed" do
      corr_id = Ecto.UUID.generate()
      cause_id = Ecto.UUID.generate()

      assert {:ok, event} =
               EmittableEvent.emit(%{order_id: "o4", amount: 400},
                 correlation_id: corr_id,
                 causation_id: cause_id
               )

      assert event.correlation_id == corr_id
      assert event.causation_id == cause_id
    end

    test "schema without idempotency_key override emits with nil key" do
      assert {:ok, event} = EmittableNoIdempotencyEvent.emit(%{name: "test"})

      assert event.type == "schema_test:emittable_no_idemp"
      assert event.idempotency_key == nil
      assert event.source == nil
    end

    test "invalid payload returns validation error" do
      assert {:error, %Forja.ValidationError{}} =
               EmittableEvent.emit(%{order_id: "o5", amount: -1})
    end

    test "idempotent emit returns :already_processed" do
      assert {:ok, _} = EmittableEvent.emit(%{order_id: "dup1", amount: 100})

      # Mark as processed so the second emit returns :already_processed
      event = Repo.one!(Forja.Event)
      Repo.update!(Forja.Event.mark_processed_changeset(event))

      assert {:ok, :already_processed} = EmittableEvent.emit(%{order_id: "dup1", amount: 100})
    end
  end

  describe "Schema.emit_multi/2,3" do
    test "adds event to Multi with schema defaults" do
      assert {:ok, result} =
               Ecto.Multi.new()
               |> EmittableEvent.emit_multi(payload: %{order_id: "m1", amount: 500})
               |> Forja.transaction(:schema_emit_test)

      event = result[:"forja_event_schema_test:emittable"]
      assert event.type == "schema_test:emittable"
      assert event.source == "test_source"
      assert event.idempotency_key == "emittable:m1"
    end

    test "works with payload_fn" do
      assert {:ok, result} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:data, fn _repo, _changes ->
                 {:ok, %{order_id: "m2", amount: 600}}
               end)
               |> EmittableEvent.emit_multi(
                 payload_fn: fn %{data: data} ->
                   %{order_id: data.order_id, amount: data.amount}
                 end
               )
               |> Forja.transaction(:schema_emit_test)

      event = result[:"forja_event_schema_test:emittable"]
      assert event.type == "schema_test:emittable"
      assert event.payload == %{"order_id" => "m2", "amount" => 600}
    end
  end

  describe "Schema without forja option" do
    test "does not generate emit/1,2" do
      refute function_exported?(NonEmittableEvent, :emit, 1)
      refute function_exported?(NonEmittableEvent, :emit, 2)
    end

    test "does not generate emit_multi/2,3" do
      refute function_exported?(NonEmittableEvent, :emit_multi, 1)
      refute function_exported?(NonEmittableEvent, :emit_multi, 2)
    end
  end
end
