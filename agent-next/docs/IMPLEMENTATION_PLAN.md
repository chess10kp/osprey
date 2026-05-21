# Implementation Plan (Jackal repo)

## Scope
Implement the new coding agent in this repo (not in external plugin repos).

## Phase 0
- Prove headless runtime boot and event streaming in-process.
- Record evidence and constraints.

## Phase 1
- Add dependency/runtime wiring for adapter-emitted artifacts.
- Introduce `@jac/pi`-style facade shim target in generated runtime.

## Phase 2
- Build adapter store + event bridge.
- Expose hooks/actions used by TUI layer.

## Phase 3
- Extension UI bridge (notify/select/input/status/widgets where supported).
- Capability gating + degraded behavior for unsupported UI factories.

## Phase 4
- Auth + model picker overlays.
- Session lifecycle + slash-command integration.

## Acceptance
- End-to-end prompt loop runs from Jackal host.
- Extension hooks work with explicit capability boundaries.
- Changes are validated with Jac/Pi checks and runtime smoke tests.
