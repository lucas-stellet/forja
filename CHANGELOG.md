# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
