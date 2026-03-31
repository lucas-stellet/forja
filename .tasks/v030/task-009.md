# Task 009: Final Verification

**Wave**: 4 | **Effort**: S
**Depends on**: task-007, task-008
**Blocks**: none

## Objective

Verify the entire migration is clean: no compilation warnings, full test suite passes, no stale references to removed modules or concepts.

## Files

No files modified — read-only verification.

## Requirements

1. **Clean compile:**

```bash
cd /Users/lucas/astride/forja && mix clean && mix compile --warnings-as-errors
```

Expected: 0 warnings, 0 errors

2. **Full test suite:**

```bash
cd /Users/lucas/astride/forja && mix test
```

Expected: ALL PASS, 0 failures

3. **Stale reference check:**

```bash
grep -r "EventProducer\|EventConsumer\|EventWorker\|AdvisoryLock\|advisory_lock\|notify_producers\|consumer_pool_size\|:genstage" lib/ test/ --include="*.ex" --include="*.exs"
```

Expected: No matches

4. **No gen_stage dependency:**

```bash
grep gen_stage mix.exs mix.lock
```

Expected: No matches (or only in lock file if not yet cleaned — run `mix deps.clean gen_stage` if needed)

5. **Version check:**

```bash
grep '@version' mix.exs
```

Expected: `@version "0.3.0"`

## Done when

- [ ] `mix compile --warnings-as-errors` — 0 warnings
- [ ] `mix test` — all pass
- [ ] No stale references in lib/ or test/
- [ ] Version is 0.3.0
- [ ] Final commit if any fixes were needed
