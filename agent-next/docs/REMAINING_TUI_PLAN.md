# Immediate Plan — Simple Working TUI (Send/Receive Only)

## Scope (for now)
Build only a minimal terminal UI that:
1. accepts typed input
2. sends a prompt
3. displays streaming/final assistant response
4. supports `/exit` and `/clear`

Everything related to Pi interop polish (auth overlays, model picker UX, tool rendering, extension integration) is deferred.

---

## MVP Tasks

### 1) Keep shell minimal
- Keep `agent-next/templates/shell.cl.jac` focused on:
  - header
  - message output area
  - single-line input
  - status line
- Remove/avoid extra UI branches not needed for send/receive.

### 2) Keep runner minimal
- `agent-next/templates/runner.mjs` should only:
  - boot adapter
  - inject `globalThis.__jackal`
  - mount app
  - handle SIGINT/SIGTERM cleanup

### 3) Basic commands only
- `/exit` or `/quit` → quit process
- `/clear` → clear local transcript
- all other text → send via `adapter.actions.send()`

### 4) Stable default model behavior
- If model is available/authenticated, set one default.
- If not, show clear status text instead of crashing.

---

## Verification (required)
Run in a real TTY:
1. `jac lint agent-next/templates/shell.cl.jac`
2. `jac run agent-next/bin/jackal_shell.jac`
3. Send test prompt: `Say pong`
4. Confirm assistant response is shown.
5. Confirm `/clear` and `/exit` work.

---

## Deferred Until Later
- Provider login flows and overlays
- Model picker UI
- Tool call rendering
- Session persistence
- Extension-level Pi interop features
- Launcher/packaging polish

This keeps the next milestone strictly: **a simple, reliable chat TUI**.
