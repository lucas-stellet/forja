# Testing

Forja provides the `Forja.Testing` module with helpers for verifying event emission and processing in your test suite.

## Setup

Import `Forja.Testing` in your test modules:

```elixir
defmodule MyApp.OrderTest do
  use MyApp.DataCase
  import Forja.Testing

  # ...
end
```

## Asserting events were emitted

### `assert_event_emitted/3`

Verifies that an event of the given type was persisted in the database:

```elixir
test "creates order and emits event" do
  {:ok, order} = MyApp.Orders.create_order(%{total: 5000})

  # Assert the event exists
  event = assert_event_emitted(:my_app, MyApp.Events.OrderCreated)
  assert event.source == "orders"

  # Assert with payload matching
  assert_event_emitted(:my_app, MyApp.Events.OrderCreated, %{"total" => 5000})
end
```

Payload matching checks that the event payload contains the specified keys with matching values. It does not require an exact match -- extra keys in the payload are allowed.

### `refute_event_emitted/2`

Verifies that no event of the given type exists:

```elixir
test "invalid order does not emit event" do
  {:error, _} = MyApp.Orders.create_order(%{total: -1})

  refute_event_emitted(:my_app, MyApp.Events.OrderCreated)
end
```

## Processing events synchronously

### `process_all_pending/1`

Processes all unprocessed events synchronously using the `:inline` path. This is useful when you need handlers to execute before making assertions:

```elixir
test "handler sends notification" do
  Forja.emit(:my_app, MyApp.Events.OrderCreated, payload: %{"order_id" => "123"})

  # Process all pending events (handlers execute here)
  process_all_pending(:my_app)

  # Now assert on side effects
  assert_received {:notification_sent, "123"}
end
```

## Idempotency testing

### `assert_event_deduplicated/2`

Verifies that exactly one event exists with the given idempotency key:

```elixir
test "duplicate emission is prevented" do
  Forja.emit(:my_app, MyApp.Events.OrderCreated,
    payload: %{"order_id" => "123"},
    idempotency_key: "order-123"
  )

  # Second emission with same key
  Forja.emit(:my_app, MyApp.Events.OrderCreated,
    payload: %{"order_id" => "123"},
    idempotency_key: "order-123"
  )

  # Only one event exists
  assert_event_deduplicated(:my_app, "order-123")
end
```

## Testing handlers in isolation

### `invoke_handler/4`

Calls a handler directly with a fabricated event, without persisting anything:

```elixir
test "OrderNotifier sends email for order:created" do
  result = invoke_handler(
    MyApp.Events.OrderNotifier,
    "order:created",
    %{"order_id" => "123", "email" => "user@example.com"}
  )

  assert result == :ok
  assert_received {:email_sent, "user@example.com"}
end
```

This is useful for unit testing handler logic without the full Forja infrastructure.
