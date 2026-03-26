defmodule Forja.Testing do
  @moduledoc """
  Helpers for testing applications that use Forja.

  Provides functions to verify that events were emitted and to
  process pending events synchronously in tests.

  ## Inline mode

  In tests, Forja can be configured to process events synchronously
  without GenStage or Oban:

      start_supervised!(
        {Forja,
         name: :test,
         repo: MyApp.Repo,
         pubsub: MyApp.PubSub,
         handlers: [MyHandler]}
      )

  ## Usage example

      defmodule MyApp.OrderTest do
        use MyApp.DataCase

        import Forja.Testing

        test "emitting order event" do
          Forja.emit(:test, MyApp.Events.OrderCreated, payload: %{id: 1})

          assert_event_emitted(:test, MyApp.Events.OrderCreated)
          assert_event_emitted(:test, MyApp.Events.OrderCreated, %{"id" => 1})
        end
      end
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Forja.Config
  alias Forja.Event

  @doc """
  Asserts that an event of the specified type was emitted in the `name` instance.

  Optionally verifies that the payload contains the specified fields.
  """
  @spec assert_event_emitted(atom(), String.t() | module(), map()) :: Event.t()
  def assert_event_emitted(name, type, payload_match \\ %{}) do
    type = resolve_type_string(type)
    config = Config.get(name)
    events = fetch_events(config.repo, type)

    assert events != [],
           "Expected event of type #{inspect(type)} to be emitted, but none found."

    matching = filter_by_payload(events, payload_match)

    assert matching != [],
           "Found #{length(events)} event(s) of type #{inspect(type)}, " <>
             "but none matched payload #{inspect(payload_match)}. " <>
             "Payloads found: #{inspect(Enum.map(events, & &1.payload))}"

    List.first(matching)
  end

  @doc """
  Asserts that NO event of the specified type was emitted in the `name` instance.
  """
  @spec refute_event_emitted(atom(), String.t() | module()) :: :ok
  def refute_event_emitted(name, type) do
    type = resolve_type_string(type)
    config = Config.get(name)
    events = fetch_events(config.repo, type)

    assert events == [],
           "Expected no events of type #{inspect(type)}, but found #{length(events)}."

    :ok
  end

  @doc """
  Synchronously processes all pending events (without `processed_at`).

  Useful for tests that need to ensure all handlers have been executed
  before making assertions.
  """
  @spec process_all_pending(atom()) :: :ok
  def process_all_pending(name) do
    config = Config.get(name)

    events =
      config.repo.all(
        from(e in Event, where: is_nil(e.processed_at), order_by: [asc: e.inserted_at])
      )

    Enum.each(events, fn event ->
      Forja.Processor.process(name, event.id, :inline)
    end)

    :ok
  end

  @doc """
  Asserts that an event with the given idempotency key was deduplicated.

  Verifies that exactly one event exists with the specified key, confirming
  deduplication worked correctly.
  """
  @spec assert_event_deduplicated(atom(), String.t()) :: Event.t()
  def assert_event_deduplicated(name, idempotency_key) do
    config = Config.get(name)

    events =
      config.repo.all(from(e in Event, where: e.idempotency_key == ^idempotency_key))

    assert length(events) == 1,
           "Expected exactly 1 event with idempotency_key #{inspect(idempotency_key)}, " <>
             "but found #{length(events)}."

    List.first(events)
  end

  @doc """
  Invokes a handler directly with a fabricated event.

  Useful for testing handlers in isolation without emitting real events.
  """
  @spec invoke_handler(module(), String.t() | module(), map(), map()) :: :ok | {:error, term()}
  def invoke_handler(handler_module, type, payload \\ %{}, meta \\ %{}) do
    type = resolve_type_string(type)

    event = %Event{
      id: Ecto.UUID.generate(),
      type: type,
      payload: payload,
      meta: meta,
      inserted_at: DateTime.utc_now()
    }

    handler_module.handle_event(event, meta)
  end

  defp fetch_events(repo, type) do
    repo.all(from(e in Event, where: e.type == ^type, order_by: [asc: e.inserted_at]))
  end

  defp filter_by_payload(events, payload_match) when map_size(payload_match) == 0 do
    events
  end

  defp filter_by_payload(events, payload_match) do
    Enum.filter(events, fn event ->
      Enum.all?(payload_match, fn {key, value} ->
        string_key = to_string(key)
        Map.get(event.payload, string_key) == value
      end)
    end)
  end

  defp resolve_type_string(type) when is_binary(type), do: type

  defp resolve_type_string(module) when is_atom(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :event_type, 0) do
      module.event_type()
    else
      raise ArgumentError, "#{inspect(module)} does not export event_type/0"
    end
  end
end
