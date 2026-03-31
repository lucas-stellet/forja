# Task 003: Event Schema — Add `queue` Macro

**Wave**: 1 | **Effort**: S
**Depends on**: none
**Blocks**: task-006

## Objective

Add a `queue` macro to the `Forja.Event.Schema` DSL so event schemas can declare which Oban queue they should be processed on. Generates a `queue/0` function.

## Files

**Modify:** `lib/forja/event/schema.ex` — add macro, generate function
**Modify:** `test/forja/event/schema_test.exs` — add tests

## Requirements

In `lib/forja/event/schema.ex`:

1. Add `@forja_queue nil` in `__using__` macro body (after `@forja_payload_used false`)

2. Add macro after `schema_version`:

```elixir
@doc """
Sets the Oban queue for this event type.

Forja prefixes the name with `forja_` internally. For example,
`queue :payments` routes to the `:forja_payments` Oban queue.

## Example

    queue :payments
"""
defmacro queue(name) when is_atom(name) do
  quote do
    @forja_queue unquote(name)
  end
end
```

3. In `__before_compile__/1`, read queue attribute:

```elixir
queue_value = Module.get_attribute(env.module, :forja_queue)
```

4. In the generated `quote` block, add:

```elixir
def queue, do: unquote(queue_value)
```

5. Update `@moduledoc` generated functions list to include `queue/0`.

In `test/forja/event/schema_test.exs`:

```elixir
defmodule QueuedEvent do
  use Forja.Event.Schema
  event_type "test:queued"
  schema_version 1
  queue :payments
  payload do
    field :id, Zoi.string()
  end
end

defmodule DefaultQueueEvent do
  use Forja.Event.Schema
  event_type "test:default_queue"
  payload do
    field :id, Zoi.string()
  end
end

test "queue/0 returns configured queue name" do
  assert QueuedEvent.queue() == :payments
end

test "queue/0 returns nil when not configured" do
  assert DefaultQueueEvent.queue() == nil
end
```

## Done when

- [ ] `mix test test/forja/event/schema_test.exs` passes
- [ ] `queue :payments` macro works in schema DSL
- [ ] `queue/0` returns configured atom or `nil`
- [ ] Committed
