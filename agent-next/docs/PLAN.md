# Plan: Jackal Agent-Next to Working TUI

## Current State

What works (verified, compiles clean):
- `src/adapter.ts` — `createNextAgent()` boots a Pi session with auth, store, bridge
- `src/store.ts` — immutable snapshot store
- `src/bridge.ts` — Pi events → store mutations
- `src/ui-context.ts` — headless ExtensionUIContext (dialogs, notify)
- `src/auth-flow.ts` — login state machine
- `src/auth-actions.ts` — drives AuthStorage/ModelRegistry

What exists in jac-tui (`~/repos/jac-tui`):
- **jac-ink** — compiles `.cl.jac` → Ink app (`.jac/tui/runner.mjs`)
- Phase 1 `@jac/pi` dependency wiring (`--with_pi`, shims, pinned Pi deps)
- Design doc: `docs/pi-interop-plan.md`

What is next:
- Wire `shell.cl.jac` to the adapter via `@jac/pi` hooks (jac-ink Phase 2+)
- Port adapter-backed features into Ink components
- Fold TS adapter into jac-ink's `jac_pi_adapter.mjs` (upstream)

## Decision: jac-ink (Ink)

**jac-ink is the UI stack because:**
- **`~/repos/jac-tui` has the Ink renderer** (jac-ink plugin)
- Jackal is Jac-first — shell UI belongs in `.cl.jac`, compiled with `jac tui`
- Headless TS adapter (`createNextAgent`, store, auth) maps to `@jac/pi` facade
- Ink owns 100% of terminal rendering

## Phases

### Phase A: Build Pipeline ✅
Compiled `agent-next/src/*.ts` → `agent-next/dist/*.js`

### Phase B: Headless adapter ✅
Store, bridge, auth, ExtensionUIContext — no rendering layer

### Phase C: jac-ink shell (current)
**Goal:** `jac tui templates/shell.cl.jac --with_pi` boots Jackal

Tasks:
1. Expand `shell.cl.jac` `app()` — Ink layout (header, messages, input, status)
2. Connect to adapter via `@jac/pi` hooks (or interim import of `dist/index.js`)
3. Keyboard/commands: send, abort, /login, /model, /clear, /exit
4. Subscribe to store snapshots for streaming + tool timeline

Deliverable: prompt/response through jac-ink

### Phase D: Auth + tool overlays (Ink)
Auth flow UI and tool timeline as Ink components

### Phase E: Integration
1. `jackal.sh` / `jackal_shell.jac` launch `jac tui`
2. Fold TS adapter into jac-ink's `jac_pi_adapter.mjs` (upstream)

## File map

```
agent-next/
├── dist/                  # compiled adapter (interim)
├── src/                   # headless adapter
├── templates/
│   └── shell.cl.jac       # Ink runtime (jac-ink)
└── bin/
    └── jackal_shell.jac   # jac tui launcher

~/repos/jac-tui/
└── jac-ink/               # compiler + @jac/pi shims + jac_pi_adapter (Phase 2+)
```
