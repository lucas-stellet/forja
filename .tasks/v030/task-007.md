# Task 007: Delete Removed Modules

**Wave**: 3 | **Effort**: S
**Depends on**: task-006
**Blocks**: task-009

## Objective

Delete the GenStage and AdvisoryLock modules and their test files. Fix any remaining stale references.

## Files

**Delete:** `lib/forja/event_producer.ex`
**Delete:** `lib/forja/event_consumer.ex`
**Delete:** `lib/forja/event_worker.ex`
**Delete:** `lib/forja/advisory_lock.ex`
**Delete:** `test/forja/event_producer_test.exs`
**Delete:** `test/forja/event_consumer_test.exs`
**Delete:** `test/forja/advisory_lock_test.exs`

## Requirements

1. Delete all 7 files listed above
2. Run `mix test` to verify no remaining references
3. If any test still references `:genstage`, `EventProducer`, `EventConsumer`, `EventWorker`, or `AdvisoryLock`, fix it. Common places:
   - `test/forja/correlation_propagation_test.exs`
   - `test/forja/correlation_test.exs`

## Done when

- [ ] All 7 files deleted
- [ ] `mix test` passes
- [ ] `grep -r "EventProducer\|EventConsumer\|EventWorker\|AdvisoryLock" lib/ test/ --include="*.ex" --include="*.exs"` returns no matches
- [ ] Committed
