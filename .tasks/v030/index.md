# Task Plan: Forja v0.3.0 — Oban-Only Architecture

> Generated from: `docs/superpowers/plans/2026-03-30-oban-only-architecture.md`
> Spec: `docs/superpowers/specs/2026-03-30-oban-only-architecture-design.md`
> Total tasks: 9 | Waves: 5 | Max parallelism: 2

## Waves

### Wave 0 — Foundation (Telemetry + Config)
| Task | Title | Effort | Files |
|------|-------|--------|-------|
| [task-001](task-001.md) | Telemetry — remove dead code, refactor signatures | M | `lib/forja/telemetry.ex`, `test/forja/telemetry_test.exs` |
| [task-002](task-002.md) | Config — remove `consumer_pool_size`, add `default_queue` | S | `lib/forja/config.ex`, `test/forja/config_test.exs` |

### Wave 1 — Schema + Processor
| Task | Title | Effort | Files | Depends on |
|------|-------|--------|-------|------------|
| [task-003](task-003.md) | Event Schema — add `queue` macro | S | `lib/forja/event/schema.ex`, `test/forja/event/schema_test.exs` | none |
| [task-004](task-004.md) | Processor — remove advisory lock, add safe_broadcast | M | `lib/forja/processor.ex`, `test/forja/processor_test.exs` | task-001 |

### Wave 2 — Workers + Main Module
| Task | Title | Effort | Files | Depends on |
|------|-------|--------|-------|------------|
| [task-005](task-005.md) | Workers — update ProcessEventWorker and ReconciliationWorker | M | `lib/forja/workers/*.ex`, `test/forja/workers/*.exs` | task-004 |
| [task-006](task-006.md) | Main Module — remove GenStage, add transaction/2, broadcast_event/2 | L | `lib/forja.ex`, `test/forja_test.exs` | task-001, task-002, task-003, task-004 |

### Wave 3 — Cleanup
| Task | Title | Effort | Files | Depends on |
|------|-------|--------|-------|------------|
| [task-007](task-007.md) | Delete removed modules | S | deletions only | task-006 |
| [task-008](task-008.md) | Update docs, handler, testing, mix.exs | S | `lib/forja/handler.ex`, `lib/forja/testing.ex`, `mix.exs` | task-006 |

### Wave 4 — Verification
| Task | Title | Effort | Files | Depends on |
|------|-------|--------|-------|------------|
| [task-009](task-009.md) | Final verification — compile, test suite, stale refs | S | none (read-only) | task-007, task-008 |

## Dependency Graph

```
task-001 (Telemetry) ──→ task-004 (Processor) ──→ task-005 (Workers) ──→ ╮
task-001 (Telemetry) ──→ task-006 (Main Module) ───────────────────────→ │
task-002 (Config) ─────→ task-006 (Main Module) ───────────────────────→ ├→ task-007 (Delete) ──→ task-009 (Verify)
task-003 (Schema) ─────→ task-006 (Main Module) ───────────────────────→ │
                         task-004 (Processor) ──→ task-006 (Main Module) ╯
                                                                         ╰→ task-008 (Docs)   ──→ task-009 (Verify)
```

## File Conflict Check

| Shared File | Tasks | Waves | Conflict? |
|---|---|---|---|
| `lib/forja/telemetry.ex` | task-001 | Wave 0 | No — single task |
| `lib/forja/config.ex` | task-002 | Wave 0 | No — single task |
| `lib/forja/processor.ex` | task-004 | Wave 1 | No — single task |
| `lib/forja.ex` | task-006 | Wave 2 | No — single task |
| `mix.exs` | task-008 | Wave 3 | No — single task |

No file conflicts within any wave.

## Notes

- Wave 1 has task-003 (Schema) which has no dependencies — it could have been in Wave 0, but the 2-agent limit pushes it to Wave 1 where it runs alongside task-004.
- Wave 2 is slightly unbalanced (task-006 is L, task-005 is M), but both are substantial enough that parallelism is valuable.
- Wave 3 tasks modify completely different files: task-007 deletes GenStage/AdvisoryLock files, task-008 modifies handler.ex/testing.ex/mix.exs.
