# Task 008: Update Docs, Handler, Testing, mix.exs

**Wave**: 3 | **Effort**: S
**Depends on**: task-006
**Blocks**: task-009

## Objective

Update moduledocs in handler.ex and testing.ex to remove dual-path references. Bump mix.exs version to 0.3.0, update description, clean up `groups_for_modules`.

## Files

**Modify:** `lib/forja/handler.ex` — update moduledoc
**Modify:** `lib/forja/testing.ex` — update moduledoc
**Modify:** `mix.exs` — version, description, deps, groups_for_modules

## Requirements

### `lib/forja/handler.ex`

- Replace "dual-path pipeline" with "Oban processing pipeline" in moduledoc
- Update `:path` values in `handle_event/2` doc (line ~65): remove `:genstage`, keep `:oban`, `:reconciliation`, `:inline`

### `lib/forja/testing.ex`

- Change "without GenStage or Oban" to "synchronously without Oban" in inline mode comment

### `mix.exs`

1. Change `@version "0.2.2"` to `@version "0.3.0"`
2. Update `description` to `"Event Bus with Oban-backed processing for Elixir."`
3. Remove `{:gen_stage, "~> 1.2"}` from `deps` if present
4. In `groups_for_modules/0`:
   - Remove the entire `"GenStage Pipeline"` group (references deleted modules)
   - Remove `Forja.AdvisoryLock` from the `Infrastructure` group

## Done when

- [ ] `mix compile --warnings-as-errors` passes
- [ ] Version is 0.3.0 in mix.exs
- [ ] No GenStage references in handler.ex or testing.ex moduledocs
- [ ] `groups_for_modules` no longer references deleted modules
- [ ] Committed
