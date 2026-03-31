# Task 005: Workers — Update ProcessEventWorker and ReconciliationWorker

**Wave**: 2 | **Effort**: M
**Depends on**: task-004
**Blocks**: task-007

## Objective

Update both Oban workers for the new Processor return type (no `{:skipped, :locked}`), increase unique period to 900s, and add Oban job existence check to ReconciliationWorker.

## Files

**Modify:** `lib/forja/workers/process_event_worker.ex` — remove locked clause, change unique period
**Modify:** `lib/forja/workers/reconciliation_worker.ex` — remove locked clause, add `has_active_oban_job?/2`
**Modify:** `test/forja/workers/process_event_worker_test.exs` — verify existing tests still pass
**Modify:** `test/forja/workers/reconciliation_worker_test.exs` — add Oban job check test

## Requirements

### ProcessEventWorker

1. Change `unique: [keys: [:event_id], period: 300]` to `unique: [keys: [:event_id], period: 900]`
2. Remove `{:skipped, :locked} -> :ok` clause from `perform/1`
3. Update `@moduledoc` — remove dual-path references

### ReconciliationWorker

1. Remove `{:skipped, :locked} -> :ok` clause from `reconcile_event/4`
2. Add `has_active_oban_job?/2` guard before processing:

```elixir
defp reconcile_event(config, forja_name, event, max_retries) do
  if has_active_oban_job?(config.repo, event.id) do
    :ok
  else
    case Forja.Processor.process(forja_name, event.id, :reconciliation) do
      :ok -> Telemetry.emit_reconciled(forja_name, event.id)
      {:error, _reason} ->
        updated_event = event |> Event.increment_reconciliation_changeset() |> config.repo.update!()
        if updated_event.reconciliation_attempts >= max_retries do
          Telemetry.emit_abandoned(forja_name, event.id, updated_event.reconciliation_attempts)
          DeadLetter.maybe_notify(config.dead_letter, updated_event, :reconciliation_exhausted)
        end
    end
  end
end

defp has_active_oban_job?(repo, event_id) do
  import Ecto.Query
  repo.exists?(
    from(j in "oban_jobs",
      where: j.worker == "Forja.Workers.ProcessEventWorker",
      where: fragment("?->>'event_id' = ?", j.args, ^event_id),
      where: j.state in ["available", "executing", "scheduled", "retryable"]
    )
  )
end
```

3. Update `@moduledoc` to remove GenStage references

### Tests

Add to `test/forja/workers/reconciliation_worker_test.exs`:

```elixir
test "skips events that have an active Oban job" do
  # Insert event, insert active Oban job for it, verify reconciliation skips
end
```

## Done when

- [ ] `mix test test/forja/workers/` passes
- [ ] ProcessEventWorker unique period is 900
- [ ] No `{:skipped, :locked}` clauses in either worker
- [ ] ReconciliationWorker skips events with active Oban jobs
- [ ] Committed
