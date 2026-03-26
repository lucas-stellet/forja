defmodule Forja.EventSchemaEmitTest do
  use Forja.DataCase, async: false

  alias Forja.Event

  defmodule ValidTestEvent do
    use Forja.Event.Schema

    event_type("schema_test:valid")
    schema_version(2)

    payload do
      field(:user_id, Zoi.string())
      field(:amount_cents, Zoi.integer() |> Zoi.positive())
      field(:currency, Zoi.string() |> Zoi.default("USD"), required: false)
    end
  end

  defmodule InvalidTestEvent do
    use Forja.Event.Schema

    event_type("schema_test:invalid")
    schema_version(1)

    payload do
      field(:user_id, Zoi.string())
      field(:amount_cents, Zoi.integer() |> Zoi.positive())
    end
  end

  defmodule MissingRequiredEvent do
    use Forja.Event.Schema

    event_type("schema_test:missing_required")
    schema_version(1)

    payload do
      field(:user_id, Zoi.string())
      field(:email, Zoi.string(), required: true)
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

  describe "emit/3 with string type (backward compatibility)" do
    test "still works unchanged, schema_version defaults to 1" do
      assert {:ok, event} =
               Forja.emit(:schema_emit_test, "schema_test:legacy",
                 payload: %{"order_id" => "123"},
                 source: "test"
               )

      assert event.type == "schema_test:legacy"
      assert event.schema_version == 1
      assert event.payload == %{"order_id" => "123"}
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
end
