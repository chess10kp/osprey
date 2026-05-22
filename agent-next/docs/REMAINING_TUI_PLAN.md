# Remaining TUI Plan (Agent-Next)

## Goal
Ship a **daily-usable Ink TUI** for Jackal with reliable send/receive, auth/model UX, tool visibility, and session persistence.

## Guardrails
- Use `reference/nanocoder` for Ink interaction patterns.
- Do **not** copy UI patterns from `reference/pi` (different framework).
- Keep adapter logic in `src/*.ts`; keep UI orchestration in `templates/shell.mjs`.
- Reuse installed Pi SDK packages (`@earendil-works/pi-ai`, `@earendil-works/pi-coding-agent`, `@earendil-works/pi-tui`) rather than custom reimplementations.

## Milestone 1 — Stabilize core chat loop
1. Confirm `npm run build:agent` outputs clean `agent-next/dist/*.js`.
2. Ensure `shell.mjs` can:
   - send prompt,
   - stream assistant output,
   - abort active run,
   - cleanly dispose session.
3. Add smoke command (`node agent-next/templates/shell.mjs`) to docs.

**Acceptance:** 3 prompt/response cycles with no crashes or orphaned sessions.

## Milestone 2 — Auth + model overlays
1. Render provider picker overlay from `authActions.listProviders()`.
2. Implement `/login`, `/logout`, `/model` command paths.
3. Render model picker overlay from `authActions.listModels()` and apply via `setModel()`.
4. Surface auth errors inline (not only in logs).

**Acceptance:** login + model switch + successful prompt on selected model.

## Milestone 3 — Tool call timeline
1. Render tool executions in message stream:
   - tool name,
   - running/done/error state,
   - duration,
   - truncated args/result preview.
2. Add compact status summary in footer (running tools, last error).

**Acceptance:** user can follow a multi-tool turn without opening debug logs.

## Milestone 4 — Session persistence
1. Switch from in-memory session manager to disk-backed session storage.
2. Restore recent conversation on startup.
3. Add `/clear` to reset local session safely.

**Acceptance:** restart shell and continue prior session context.

## Milestone 5 — Command UX + polish
1. Add `/help` command palette output.
2. Add multiline input mode (explicit toggle or shortcut).
3. Improve scrolling/pagination for long chats.
4. Add graceful messaging for SIGINT/SIGTERM shutdown.

**Acceptance:** long-session usability without input or rendering dead-ends.

## Milestone 6 — Launch integration
1. Wire launcher (`jackal.sh` and/or `/jackal-shell`) to run built shell by default.
2. Ensure extension loading and MCP discovery still work in this path.
3. Update README with exact startup and troubleshooting commands.

**Acceptance:** one-command launch into working TUI from repo root.

## Verification checklist (run each milestone)
- `npm run build:agent`
- targeted runtime smoke test (`node agent-next/templates/shell.mjs`)
- basic prompt/tool turn
- auth/model flow (where applicable)
- restart persistence check (where applicable)

## Suggested execution order
M1 → M2 → M3 → M4 → M5 → M6

This preserves a working shell at every step and avoids blocking on polish before core reliability.
