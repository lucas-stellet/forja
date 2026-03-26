# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Three-layer exactly-once deduplication (advisory lock + processed_at + Oban unique)
- `Forja.emit/3` for atomic event emission
- `Forja.emit_multi/4` for transactional event emission with Ecto.Multi
- `Forja.Handler` behaviour for event handlers
- `Forja.DeadLetter` behaviour for dead letter handling
- `Forja.Testing` module with test helpers
- `Forja.Telemetry` with 9 telemetry event types
- `ReconciliationWorker` for periodic stale event recovery
- Idempotency key support for duplicate prevention
- Igniter-based installer (`mix forja.install`)
