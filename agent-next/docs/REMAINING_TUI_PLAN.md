# Remaining TUI Plan (Agent-Next)

## Goal
Ship a **daily-usable Ink shell** for Jackal via **jac-ink** (jac-tui repo), with
reliable send/receive, auth/model UX, tool visibility, and session persistence.

## Guardrails
- **UI:** jac-ink + Ink + `shell.cl.jac` only.
- Renderer lives in **`~/repos/jac-tui`** (jac-ink plugin). Follow
  [`pi-interop-plan.md`](../../jac-tui/docs/pi-interop-plan.md) and
  [`pi-interop-progress.md`](../../jac-tui/docs/pi-interop-progress.md).
- Headless adapter in `agent-next/src/*.ts` until merged into jac-ink's
  `jac_pi_adapter.mjs`; UI orchestration in `shell.cl.jac`.
- Runtime deps: `@earendil-works/pi-agent-core`, `@earendil-works/pi-ai` (via `jac.toml`; no `pi-coding-agent`).
- Use `reference/nanocoder` for Ink interaction patterns where helpful.

## Milestone 1 — jac-ink shell boots with adapter
1. `shell.cl.jac` exports `app()` and imports `@jac/pi` (or interim adapter JS).
2. `jac tui templates/shell.cl.jac --with_pi --install --run` boots from repo.
3. Wire send/stream/abort/dispose in Ink components.

**Acceptance:** 3 prompt/response cycles through jac-ink.

## Milestone 2 — Auth + model overlays (Ink)
1. Render provider/model pickers as Ink overlays from adapter state.
2. Implement `/login`, `/logout`, `/model` in `shell.cl.jac`.
3. Surface auth errors inline.

**Acceptance:** login + model switch + successful prompt on selected model.

## Milestone 3 — Tool call timeline (Ink)
1. Render tool executions in the message stream (name, state, duration, preview).
2. Footer summary for running tools and last error.

**Acceptance:** user can follow a multi-tool turn without debug logs.

## Milestone 4 — Session persistence
1. Disk-backed SessionManager (already in adapter).
2. Restore conversation on startup; `/clear` resets safely.

**Acceptance:** restart shell and continue prior session context.

## Milestone 5 — Command UX + polish
1. `/help`, multiline input, scrollback/pagination.
2. Graceful SIGINT/SIGTERM shutdown messaging.

**Acceptance:** long-session usability without input or rendering dead-ends.

## Milestone 6 — Launch integration
1. Wire `jackal.sh` / `/jackal-shell` / `jackal_shell.jac` to `jac tui`.
2. Ensure extension loading and MCP discovery work on the Ink path.

**Acceptance:** one-command launch into jac-ink TUI from repo root.

## Verification checklist
- `jac tui agent-next/templates/shell.cl.jac --with_pi --install --run`
- `npm run build:agent` (while TS adapter is still separate)
- basic prompt/tool turn
- auth/model flow
- restart persistence check

## Suggested execution order
M1 → M2 → M3 → M4 → M5 → M6
