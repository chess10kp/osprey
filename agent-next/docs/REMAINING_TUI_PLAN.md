# Immediate Plan — Simple Working TUI (Send/Receive Only)

## check out reference/nanocoder for a reference implemenation of an agent using ink

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
- [x] Runtime shell simplified in `agent-next/templates/shell.mjs`:
  - header
  - message output area
  - single-line input
  - status line
- [x] Extra command/overlay branches removed from runtime path.

### 2) Keep runner minimal
- [x] `agent-next/bin/jackal_shell.jac` now only:
  - builds adapter JS (`npm run -s build:agent`)
  - launches shell (`node agent-next/templates/shell.mjs`)
  - handles interrupt cleanly
- [ ] `agent-next/templates/runner.mjs` alignment still pending (currently not used by runtime path).

### 3) Basic commands only
- [x] `/exit` or `/quit` → quit process
- [x] `/clear` → clear local transcript
- [x] all other text → send via `adapter.actions.send()`

### 4) Stable default model behavior
- [x] If no model is configured/authenticated, show explicit status (`no model configured`, `ready (login/model needed)`).
- [x] Shell startup no longer crashes in no-model state.

---

## Verification (required)
Run in a real TTY:
1. `jac lint agent-next/templates/shell.cl.jac` ✅ (warnings only)
2. `jac run agent-next/bin/jackal_shell.jac` ✅ (boots; verify interactively)
3. Send test prompt: `Say pong` ⏳ pending manual interactive check
4. Confirm assistant response is shown ⏳ pending manual interactive check
5. Confirm `/clear` and `/exit` work ⏳ pending manual interactive check

---

## Deferred Until Later
- Provider login flows and overlays
- Model picker UI
- Tool call rendering
- Session persistence
- Extension-level Pi interop features
- Launcher/packaging polish

This keeps the next milestone strictly: **a simple, reliable chat TUI**.
