# Plan: Jackal Agent-Next to Working TUI

## Current State

What works (verified, compiles clean):
- `src/adapter.ts` — `createNextAgent()` boots a Pi session with auth, store, bridge
- `src/store.ts` — immutable snapshot store
- `src/bridge.ts` — Pi events → store mutations
- `src/ui-context.ts` — headless ExtensionUIContext (dialogs, notify)
- `src/auth-flow.ts` — login state machine
- `src/auth-actions.ts` — drives AuthStorage/ModelRegistry
- Smoke test verified end-to-end inside Pi's TUI

What doesn't exist yet:
- No build pipeline to compile TS → JS
- No `app()` entry in shell.cl.jac (it's fragments only)
- `@jac/pi` hooks are stubs — no bridge from .cl.jac to Pi SDK
- jackal_shell.jac scaffolds but references deleted shell.mjs
- Nobody has typed a prompt and seen a response through this stack

## Decision: Path A — JS shell with TS adapter

**Why not Path B (implement @jac/pi hooks):**
- Requires extending jac-ink plugin (different repo)
- Pi SDK is Node.js, jac-ink runs in Vite/browser-adjacent context
- The hook API surface is unclear (usePiSession returns what?)
- Would be weeks of work for unclear benefit

**Path A is the right call because:**
- All 1139 lines of TS adapter code already compile and work
- Pi SDK (`@earendil-works/pi-coding-agent`) is an npm package — importable from Node
- `pi-tui` provides rich Ink components (Input, SelectList, Markdown, Editor)
- One build step (tsc) gives us importable JS
- The shell is a single `shell.mjs` that imports our adapter + pi-tui components

## Phases

### Phase A: Build Pipeline (30 min)
**Goal:** `npm run build` compiles agent-next/src/*.ts → agent-next/dist/*.js

Tasks:
1. Add `tsconfig.json` to agent-next/ (target ESM, outDir dist)
2. Add `"build": "tsc"` script
3. Verify: `node -e "import('./agent-next/dist/adapter.js')"` resolves

Deliverable: compiled JS in agent-next/dist/

### Phase B: Working Shell (2 hrs)
**Goal:** `node shell.mjs` boots, accepts input, shows streaming responses

Tasks:
1. Write `shell.mjs` — standalone Ink app that:
   - Imports `createNextAgent` from compiled adapter
   - Imports `Input`, `Text`, `Box` from `pi-tui` (already a dep)
   - Renders Header, messages, streaming text, status bar, input
   - Handles keyboard (Input component from pi-tui handles this)
   - Wires send/resolveDialog/dispose to the adapter
2. This replaces shell.cl.jac as the runtime target
   - shell.cl.jac stays as presentational components (can be used later)
   - shell.mjs is what actually runs

Deliverable: type a prompt, see a streaming response

### Phase C: Auth Flow (1 hr)
**Goal:** /login and /model commands work in the shell

Tasks:
1. Auth overlay — render provider list from authActions.listProviders()
2. Model overlay — render model list from authActions.listModels()
3. Wire /login <provider> → authActions.loginWith(provider)
4. Wire /model <provider/model> → actions.setModel()
5. Wire /logout <provider> → authActions.logout()

Deliverable: login, pick model, send prompt with chosen model

### Phase D: Tool Rendering (1 hr)
**Goal:** Tool calls appear in the message stream with name, status, result

Tasks:
1. Render tool_executions from store snapshot
2. Show running (spinner) → done (result preview)
3. Truncate long inputs/results
4. Show tool count in status bar

Deliverable: see read/edit/bash tools executing in real time

### Phase E: Polish & Integration (1 hr)
**Goal:** shell is usable as daily driver, wired into jackal.sh

Tasks:
1. Markdown rendering for assistant messages (pi-tui Markdown component)
2. Scrollback (last N messages)
3. Session persistence (SessionManager.disk-backed instead of inMemory)
4. Wire into jackal.sh launcher
5. Update /jackal-shell command to run the built shell

Deliverable: `./jackal.sh` launches the new TUI

## What shell.cl.jac / jackal_shell.jac become

- `shell.cl.jac` — stays as-is. Presentational components usable when
  jac-ink gets real @jac/pi hooks (future work). Not used at runtime.
- `jackal_shell.jac` — becomes a thin wrapper that runs `node shell.mjs`
  instead of scaffolding. Or removed entirely once jackal.sh works.

## File map after completion

```
agent-next/
├── tsconfig.json          # NEW — build config
├── dist/                  # NEW — compiled JS (gitignored)
│   ├── adapter.js
│   ├── store.js
│   ├── bridge.js
│   ├── ui-context.js
│   ├── auth-flow.js
│   ├── auth-actions.js
│   └── index.js
├── src/                   # existing TS source (unchanged)
├── templates/
│   ├── shell.cl.jac       # presentational (not runtime)
│   └── shell.mjs          # NEW — actual runtime shell
└── bin/
    └── jackal_shell.jac   # thin runner or removed
```

## Total estimated time: ~5 hrs

### Phase A: 30 min ← start here
### Phase B: 2 hrs
### Phase C: 1 hr
### Phase D: 1 hr
### Phase E: 1 hr
