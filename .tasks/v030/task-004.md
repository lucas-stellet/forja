# Task 004: Processor — Remove Advisory Lock, Add Safe Broadcast

**Wave**: 1 | **Effort**: M
**Depends on**: task-001
**Blocks**: task-005, task-006

## Objective

Rewrite `Forja.Processor` to remove all dual-path concerns (advisory locks, `{:skipped, :locked}`). Make `dispatch_to_handlers` always return `:ok`, use non-bang `repo.update/1` for `mark_processed`, and add `safe_broadcast` post-processing.

## Files

**Modify:** `lib/forja/processor.ex` — full rewrite
**Modify:** `test/forja/processor_test.exs` — update path refs, add broadcast test
**Read:** `lib/forja/telemetry.ex` — uses new `emit_processed/2` and `emit_failed/2` from task-001

## Requirements

Replace `lib/forja/processor.ex` entirely. Key changes from current code:

1. **Remove** `alias Forja.AdvisoryLock` and the `AdvisoryLock.with_lock` wrapper
2. **Remove** `{:skipped, :locked}` from return type — new spec: `@spec process(atom(), String.t(), atom()) :: :ok | {:error, term()}`
3. **`process/3`** loads event directly (no lock wrapper), dispatches, then calls `mark_processed`
4. **`dispatch_to_handlers/4`** uses `Enum.each` (not `Enum.flat_map`), always returns `:ok`. Handler errors are handled internally via telemetry + `on_failure/3`.
5. **`mark_processed/2`** uses `config.repo.update()` (non-bang). On failure, returns `{:error, changeset}` to Oban for retry.
6. **`safe_broadcast/3`** broadcasts `{:forja_event_processed, event}` wrapped in try/rescue.
7. **Telemetry calls** use new map signatures: `Telemetry.emit_processed(name, %{type: ..., handler: ..., path: ..., duration: ...})`

See `docs/superpowers/plans/2026-03-30-oban-only-architecture.md` Task 4 Step 3 for the complete replacement code.

### Test updates in `test/forja/processor_test.exs`:

1. Replace all `:genstage` path references with `:oban` (3 occurrences)
2. Start PubSub in setup: `start_supervised!({Phoenix.PubSub, name: Forja.ProcessorTestPubSub})`
3. Update config to use real PubSub: `pubsub: Forja.ProcessorTestPubSub`
4. Add broadcast test:

```elixir
test "broadcasts :forja_event_processed after processing" do
  Phoenix.PubSub.subscribe(Forja.ProcessorTestPubSub, "forja:events")
  event = insert_event!("test:success")

  assert :ok = Processor.process(:processor_test, event.id, :oban)

  assert_receive {:forja_event_processed, %Event{id: id}}
  assert id == event.id
end
```

## Done when

- [ ] `mix test test/forja/processor_test.exs` passes
- [ ] No references to `AdvisoryLock`, `{:skipped, :locked}`, or `:genstage`
- [ ] `dispatch_to_handlers` returns `:ok` always
- [ ] `mark_processed` uses non-bang `update/1`
- [ ] PubSub broadcast test passes
- [ ] Committed
