defmodule Forja.Event.SchemaTest do
  use ExUnit.Case, async: true

  # Event schemas under test
  defmodule ValidEvent do
    use Forja.Event.Schema

    event_type("test:valid")
    schema_version(1)

    payload do
      field(:user_id, Zoi.string())
      field(:amount_cents, Zoi.integer() |> Zoi.positive())
      field(:currency, Zoi.string() |> Zoi.default("USD"), required: false)
    end
  end

  defmodule VersionedEvent do
    use Forja.Event.Schema

    event_type("test:versioned")
    schema_version(2)

    payload do
      field(:user_id, Zoi.string())
      field(:currency, Zoi.string() |> Zoi.default("USD"), required: false)
    end

    def upcast(1, payload) do
      %{user_id: payload["customer_id"], currency: "USD"}
    end
  end

  defmodule MinimalEvent do
    use Forja.Event.Schema

    event_type("test:minimal")
  end

  defmodule QueuedEvent do
    use Forja.Event.Schema

    event_type("test:queued")
    schema_version(1)
    queue(:payments)

    payload do
      field(:id, Zoi.string())
    end
  end

  defmodule DefaultQueueEvent do
    use Forja.Event.Schema

    event_type("test:default_queue")

    payload do
      field(:id, Zoi.string())
    end
  end

  describe "__forja_event_schema__/0" do
    test "returns true" do
      assert ValidEvent.__forja_event_schema__() == true
    end
  end

  describe "event_type/0" do
    test "returns configured type string" do
      assert ValidEvent.event_type() == "test:valid"
      assert VersionedEvent.event_type() == "test:versioned"
    end
  end

  describe "schema_version/0" do
    test "defaults to 1 when not specified" do
      assert MinimalEvent.schema_version() == 1
    end

    test "returns override value when configured" do
      assert VersionedEvent.schema_version() == 2
    end
  end

  describe "queue/0" do
    test "returns configured queue name" do
      assert QueuedEvent.queue() == :payments
    end

    test "returns nil when not configured" do
      assert DefaultQueueEvent.queue() == nil
    end
  end

  describe "parse_payload/1" do
    test "validates correct payload returns ok tuple" do
      payload = %{user_id: "user_123", amount_cents: 5000}
      assert {:ok, result} = ValidEvent.parse_payload(payload)
      assert result.user_id == "user_123"
      assert result.amount_cents == 5000
      # Optional fields with defaults are still present in result if provided
      assert is_map(result)
    end

    test "returns error for missing required field" do
      payload = %{user_id: "user_123"}
      assert {:error, errors} = ValidEvent.parse_payload(payload)
      assert is_list(errors)
      assert Enum.any?(errors, fn e -> e.path == [:amount_cents] end)
    end

    test "accepts payload without optional fields" do
      payload = %{user_id: "user_123", amount_cents: 100}
      assert {:ok, result} = ValidEvent.parse_payload(payload)
      assert result.user_id == "user_123"
      assert result.amount_cents == 100
    end

    test "returns error for wrong type" do
      payload = %{user_id: 123, amount_cents: 5000}
      assert {:error, errors} = ValidEvent.parse_payload(payload)
      assert is_list(errors)
    end

    test "returns error for negative value on positive constraint" do
      payload = %{user_id: "user_123", amount_cents: -100}
      assert {:error, errors} = ValidEvent.parse_payload(payload)
      assert is_list(errors)
    end
  end

  describe "Zoi.default values" do
    test "are overridden when field is provided" do
      payload = %{user_id: "user_123", amount_cents: 5000, currency: "EUR"}
      assert {:ok, result} = VersionedEvent.parse_payload(payload)
      assert result.currency == "EUR"
    end
  end

  describe "upcast/2" do
    test "default upcast is a no-op" do
      payload = %{user_id: "user_123"}
      assert ValidEvent.upcast(1, payload) == payload
    end

    test "custom upcast transforms old payload" do
      old_payload = %{"customer_id" => "cust_123"}
      upcasted = VersionedEvent.upcast(1, old_payload)
      assert upcasted.user_id == "cust_123"
      assert upcasted.currency == "USD"
    end
  end
end
