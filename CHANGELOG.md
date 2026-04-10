# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-04-10

### Added

- Versioned Forja migrations through `Forja.Migration` and `Forja.Migrations.Postgres.V01`

### Migration

```elixir
defmodule MyApp.Repo.Migrations.SetupForja do
  use Ecto.Migration

  def up, do: Forja.Migration.up(version: 1)
  def down, do: Forja.Migration.down(version: 0)
end
```

## [0.4.1] - 2026-04-08

### Fixed

- Fix all code examples to use schema modules instead of deprecated string event types
- Fix `attach_default_logger` docs showing incorrect arity (removed spurious name argument)
- Fix `assert_event_caused_by` docs showing wrong argument order
- Fix `emit_multi/2,3` references to correct `emit_multi/1,2` arities across all docs
- Remove non-existent `[:forja, :event, :skipped]` telemetry event from docs
- Remove false advisory lock references (deduplication is two-layer: `processed_at` + Oban unique)
- Fix `increment_reconciliation_changeset/1` doc example (was calling wrong function)
- Fix `causation_id` description in Handler meta docs
- Fix telemetry level tier table (`:info` no longer incorrectly lists `deduplicated`)
- Add missing `[:forja, :event, :validation_failed]` to telemetry guide
- Add missing columns (`schema_version`, `correlation_id`, `causation_id`) to for-agents migration guide
- Add Igniter requirement note for `mix forja.install`
- Fix ReconciliationWorker crontab example to include required `args`
- Note that automatic upcasting via Processor is not yet implemented
- Rewrite README.pt-BR.md to match current Oban-only architecture (was still describing removed GenStage)

## [0.4.0] - 2026-04-06

### Added

- `emit/1,2` and `emit_multi/1,2` generated on schema modules when `:forja` option is provided
- `:forja` option to bind a schema to a Forja instance for centralized emission
- `:source` option to set a default source for emitted events
- Overridable `idempotency_key/1` callback to derive idempotency keys from payload

### Changed

- **Breaking:** `event_type`, `schema_version`, `queue` are now options passed to `use Forja.Event.Schema` instead of standalone macros (follows the Oban.Worker pattern)
- `upcast/2` remains an overridable callback (unchanged behavior)

### Migration

```elixir
# Before (0.3.x)
use Forja.Event.Schema

event_type "order:created"
schema_version 2
queue :payments

# After (0.4.0)
use Forja.Event.Schema,
  event_type: "order:created",
  schema_version: 2,
  queue: :payments
```

## [0.3.2] - 2026-04-06

### Changed

- Updated README to reflect Oban-only architecture (removed GenStage references)
- Added event schemas, correlation/causation IDs, `on_failure/3`, and telemetry docs to README
- Added links to HexDocs guides
- Fixed version in installation instructions (`~> 0.1.0` → `~> 0.3.0`)

## [0.3.1] - 2026-03-30

### Changed

- Updated documentation and guides for v0.3.0 architecture

## [0.3.0] - 2026-03-30

### Changed

- **Breaking:** Migrated to Oban-only architecture — removed GenStage consumers (EventProducer, EventConsumer)
- PubSub broadcast is now best-effort notification only (not a processing path)
- Supervision tree reduced to a single child (ObanListener)
- Refactored telemetry event APIs

### Removed

- GenStage-based fast path processing
- `consumer_pool_size` configuration option
- EventProducer and EventConsumer modules

## [0.2.2] - 2026-03-26

### Added

- `on_failure/3` optional callback on `Forja.Handler` for handler-level failure recovery
- Error handling guide (`guides/error-handling.md`) with retry patterns, Sage integration, and examples
- Clear separation: `on_failure/3` for handler failures, `DeadLetter` for event-level failures

## [0.2.1] - 2026-03-26

### Added

- `correlation_id` and `causation_id` fields for event chain tracing
- Automatic propagation of correlation context when handlers emit new events
- `correlation_id` included in `[:forja, :event, :emitted]` telemetry metadata
- `assert_event_caused_by/3` and `assert_same_correlation/1` testing helpers
- Correlation & Causation IDs section in event-schemas guide

## [0.2.0] - 2026-03-26

### Added

- `Forja.Event.Schema` macro for defining typed event schemas with Zoi validation
- `Forja.ValidationError` struct wrapping validation errors in a Forja-owned type
- `schema_version` field on events for payload versioning and upcasting
- `[:forja, :event, :validation_failed]` telemetry event
- `upcast/2` overridable callback for schema version migrations
- Event schemas guide (`guides/event-schemas.md`)
- Payload fields are required by default in schema definitions
- `emit/3` and `emit_multi/4` accept schema modules as the type argument
- Testing helpers accept schema modules in addition to string types
- Zoi as required dependency for event schema validation

### Changed

- `emit/3` and `emit_multi/4` now require a `Forja.Event.Schema` module (string-based emission removed)

## [0.1.0] - 2026-03-26

### Added

- Dual-path event processing: GenStage (fast) + Oban (guaranteed)
- Two-layer exactly-once deduplication (processed_at + Oban unique)
- `Forja.emit/3` for atomic event emission
- `Forja.emit_multi/4` for transactional event emission with Ecto.Multi
- `Forja.Handler` behaviour for event handlers
- `Forja.DeadLetter` behaviour for dead letter handling
- `Forja.Testing` module with test helpers
- `Forja.Telemetry` with 7 telemetry event types
- `ReconciliationWorker` for periodic stale event recovery
- Idempotency key support for duplicate prevention
- Igniter-based installer (`mix forja.install`)
