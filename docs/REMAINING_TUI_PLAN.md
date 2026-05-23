# Remaining TUI Plan

## Goal
Ship a **daily-usable Ink shell** for Jackal via **jac-ink** (jac-tui repo), with
reliable send/receive, auth/model UX, tool visibility, and session persistence.

## Guardrails

### Jackal repo (agents implement here)
- **UI:** Ink components in `templates/shell.cl.jac`
- **Runtime:** headless adapter in `src/*.ts`
- **Launch:** `jackal.sh`, docs, Jackal slash workflows ported to Ink where feasible
- Runtime deps: `@earendil-works/pi-agent-core`, `@earendil-works/pi-ai` (via `jac.toml`; no `pi-coding-agent`)
- Use `reference/nanocoder` for Ink interaction patterns where helpful

### Framework / plugin (human implements — agents hand off)
- **Do not** edit `~/repos/jac-tui/jac-ink`, jaclang, or jac_client
- **Do not** write or edit shim scripts (`jac_pi_runtime_shim.mjs`, facades, emitted runtime shims)
- When jac-ink or compiler changes are needed, **tell the human**: symptom, owning repo, recommended fix
- Renderer/compiler lives in **`~/repos/jac-tui`**. Reference only:
  [`pi-interop-plan.md`](../../jac-tui/docs/pi-interop-plan.md),
  [`pi-interop-progress.md`](../../jac-tui/docs/pi-interop-progress.md),
  [JAC-TUI.md](./JAC-TUI.md),
  [`AGENTS.md`](../AGENTS.md)

## Milestone 1 — jac-ink shell boots with adapter
1. `shell.cl.jac` exports `app()` and imports `@jac/pi`.
2. `./jackal.sh` (or `jac tui templates/shell.cl.jac` after human confirms jac-ink flags) boots from repo.
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
1. Wire `jackal.sh` / `/jackal-shell` / `jackal_shell.jac` to `jac tui` (jackal repo).
2. Agent capabilities on Ink path: tools, MCP, Jackal workflows (see [FEATURES.md](./FEATURES.md)).
3. Any jac-ink compile/adapter gaps → hand off to human ([JAC-TUI.md](./JAC-TUI.md)).

**Acceptance:** one-command launch into jac-ink TUI from repo root.

## Verification checklist
- `npm run build:agent`
- `./jackal.sh` (interactive terminal)
- basic prompt/tool turn
- auth/model flow
- restart persistence check

## Suggested execution order
M1 → M2 → M3 → M4 → M5 → M6 (jackal repo work); parallel jac-ink items via human handoff
