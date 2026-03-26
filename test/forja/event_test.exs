defmodule Forja.EventTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Forja.Event

  setup do
    %{
      valid_attrs: %{
        type: "user.created",
        payload: %{"user_id" => 123},
        meta: %{"ip" => "127.0.0.1"},
        source: "identity-service",
        idempotency_key: "user-123-created-001"
      }
    }
  end

  defp errors_on(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "valid changeset with required fields only", %{valid_attrs: valid_attrs} do
      attrs = Map.drop(valid_attrs, [:payload, :meta, :source, :idempotency_key])

      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
      assert changes(changeset) == %{type: "user.created"}
    end

    test "valid changeset with all fields", %{valid_attrs: valid_attrs} do
      changeset = Event.changeset(%Event{}, valid_attrs)

      assert changeset.valid?
      assert get_change(changeset, :type) == "user.created"
      assert get_change(changeset, :payload) == %{"user_id" => 123}
      assert get_change(changeset, :meta) == %{"ip" => "127.0.0.1"}
      assert get_change(changeset, :source) == "identity-service"
      assert get_change(changeset, :idempotency_key) == "user-123-created-001"
    end

    test "invalid without type", %{valid_attrs: valid_attrs} do
      attrs = Map.delete(valid_attrs, :type)
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset) == %{type: ["can't be blank"]}
    end

    test "invalid with empty type", %{valid_attrs: valid_attrs} do
      attrs = %{valid_attrs | type: ""}
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset) == %{type: ["can't be blank"]}
    end

    test "invalid with too-long type", %{valid_attrs: valid_attrs} do
      attrs = %{valid_attrs | type: String.duplicate("a", 256)}
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset) == %{type: ["should be at most 255 character(s)"]}
    end

    test "valid at max length type", %{valid_attrs: valid_attrs} do
      attrs = %{valid_attrs | type: String.duplicate("a", 255)}
      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
    end
  end

  describe "default values" do
    test "payload defaults to empty map" do
      changeset = Event.changeset(%Event{}, %{type: "test"})

      assert %{} = Changeset.get_change(changeset, :payload) || changeset.data.payload
    end

    test "meta defaults to empty map" do
      changeset = Event.changeset(%Event{}, %{type: "test"})

      assert %{} = Changeset.get_change(changeset, :meta) || changeset.data.meta
    end

    test "reconciliation_attempts defaults to 0" do
      event = %Event{}
      assert event.reconciliation_attempts == 0
    end
  end

  describe "idempotency_key" do
    test "accepts idempotency_key", %{valid_attrs: valid_attrs} do
      changeset = Event.changeset(%Event{}, valid_attrs)

      assert get_change(changeset, :idempotency_key) == "user-123-created-001"
    end

    test "unique constraint on idempotency_key", %{valid_attrs: valid_attrs} do
      # First, create a valid changeset with idempotency_key
      changeset1 = Event.changeset(%Event{}, valid_attrs)
      assert changeset1.valid?

      # Create another event with the same idempotency_key
      duplicate_key_attrs = %{valid_attrs | type: "user.updated"}
      changeset2 = Event.changeset(%Event{}, duplicate_key_attrs)

      # The unique_constraint error would appear after DB insert
      # For changeset validation, we just verify the constraint is defined
      constraints = Changeset.constraints(changeset2)
      assert Enum.any?(constraints, fn c -> c.field == :idempotency_key && c.type == :unique end)
    end
  end

  describe "mark_processed_changeset/1" do
    test "sets processed_at to current time" do
      event = %Event{type: "test"}
      before_test = DateTime.utc_now()

      changeset = Event.mark_processed_changeset(event)

      assert changeset.changes[:processed_at] != nil
      processed_at = changeset.changes[:processed_at]
      assert DateTime.compare(processed_at, before_test) in [:gt, :eq]
    end

    test "does not modify other fields" do
      event = %Event{type: "test", payload: %{"foo" => "bar"}}
      changeset = Event.mark_processed_changeset(event)

      assert get_change(changeset, :type) == nil
      assert get_change(changeset, :payload) == nil
    end
  end

  describe "increment_reconciliation_changeset/1" do
    test "increments from 0" do
      event = %Event{type: "test", reconciliation_attempts: 0}
      changeset = Event.increment_reconciliation_changeset(event)

      assert changeset.changes[:reconciliation_attempts] == 1
    end

    test "increments from existing value" do
      event = %Event{type: "test", reconciliation_attempts: 5}
      changeset = Event.increment_reconciliation_changeset(event)

      assert changeset.changes[:reconciliation_attempts] == 6
    end

    test "handles nil as 0" do
      event = %Event{type: "test", reconciliation_attempts: nil}
      changeset = Event.increment_reconciliation_changeset(event)

      assert changeset.changes[:reconciliation_attempts] == 1
    end
  end

  # Helper to get changes from changeset
  defp changes(changeset) do
    changeset.changes
  end

  defp get_change(changeset, field) do
    Changeset.get_change(changeset, field)
  end
end
