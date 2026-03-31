# Task 002: Config — Remove `consumer_pool_size`, Add `default_queue`

**Wave**: 0 | **Effort**: S
**Depends on**: none
**Blocks**: task-006

## Objective

Remove the `consumer_pool_size` field from `Forja.Config` (no longer needed without GenStage) and add `default_queue` field for per-event Oban queue routing.

## Files

**Modify:** `lib/forja/config.ex` — update struct, type, moduledoc
**Modify:** `test/forja/config_test.exs` — remove old tests, add new ones

## Requirements

In `lib/forja/config.ex`:
1. Remove `consumer_pool_size: 4` from `defstruct`
2. Add `default_queue: :events` to `defstruct`
3. Remove `consumer_pool_size: pos_integer()` from `@type t`
4. Add `default_queue: atom()` to `@type t`
5. Update `@moduledoc` — remove `consumer_pool_size` docs, add `default_queue` docs

In `test/forja/config_test.exs`:
- Remove any tests for `consumer_pool_size`
- Add tests:

```elixir
test "default_queue defaults to :events" do
  config = Config.new(name: :test, repo: Repo, pubsub: PubSub)
  assert config.default_queue == :events
end

test "default_queue can be overridden" do
  config = Config.new(name: :test, repo: Repo, pubsub: PubSub, default_queue: :custom)
  assert config.default_queue == :custom
end

test "consumer_pool_size is not a valid option" do
  assert_raise KeyError, fn ->
    Config.new(name: :test, repo: Repo, pubsub: PubSub, consumer_pool_size: 8)
  end
end
```

## Done when

- [ ] `mix test test/forja/config_test.exs` passes
- [ ] `Config` struct no longer has `consumer_pool_size`
- [ ] `Config` struct has `default_queue` defaulting to `:events`
- [ ] Committed
