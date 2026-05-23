# Plan: Jackal Agent-Next to Working TUI

## Current State (2026-05-22)

What works (verified, runs):
- `src/adapter.ts` — `createNextAgent()` boots a Jackal session (`pi-agent-core`) with auth, store, bridge
- `src/store.ts` — immutable snapshot store
- `src/bridge.ts` — Pi events → store mutations
- `src/ui-context.ts` — headless ExtensionUIContext (dialogs, notify)
- `src/auth-flow.ts` — login state machine
- `src/auth-actions.ts` — drives `JackalAuth` / `JackalModels` (pi-ai)
- `src/completions.ts` — slash-command autocomplete

What works in jac-ink (`~/repos/jac-tui`):
- **jac-ink bypasses Vite** — uses plain `ClientBundleBuilder` for Ink apps
- **`@jac/pi` import injection** — detects hook usage and adds the import
- **Real Pi shim** — boots headless adapter, exposes all React hooks
- `agent-next/jac.toml` declares `pi-agent-core` + `pi-ai` (no `--with_pi` / no `pi-coding-agent`)

What runs:
- `./jackal.sh` or `jac tui templates/shell.cl.jac` → compiles, installs, starts
- Ink renders the shell UI with all components
- Requires an interactive terminal (raw mode for input)

## Upstream patches applied (site-packages)

1. `jac_client/plugin/src/impl/compiler.impl.jac` — fixed `.cl.jac` stem bug
   - `module_path.stem` returns `shell.cl` but compiled JS is `shell.js`
   - Added `_js_module_stem()` helper that strips `.cl.jac` correctly

2. `jaclang/runtimelib/impl/client_bundle.impl.jac` — skip `@jac/pi` bundling
   - `@jac/pi` is a virtual import resolved by jac-ink's shim, not a real module
   - Prevents the import from being stripped during bundle processing

3. `jac-tui/jac-ink/jac_ink/plugin/cli.jac` — three changes:
   - Use `ClientBundleBuilder` instead of Vite (Ink runs in Node, not browser)
   - `_ensure_pi_import()` adds `@jac/pi` import when hooks are detected
   - Real shim with adapter boot + React hooks (replaces Phase 1 stubs)

## Phases

### Phase A: Build Pipeline ✅
Compiled `agent-next/src/*.ts` → `agent-next/dist/*.js`

### Phase B: Headless adapter ✅
Store, bridge, auth, ExtensionUIContext — no rendering layer

### Phase C: jac-ink compilation pipeline ✅
`./jackal.sh` compiles and runs (facade copied into `.jac/tui/`)

### Phase D: Interactive shell (current)
**Goal:** Full interactive prompt/response through the Ink shell

Remaining:
1. Test with real Pi credentials (auth flow)
2. Verify streaming text renders correctly
3. Verify tool execution timeline
4. Test /login, /model, /abort commands
5. Test multiline input

### Phase E: Integration
1. `jackal.sh` / `jackal_shell.jac` launch `jac tui`
2. Fold TS adapter into jac-ink's `jac_pi_adapter.mjs` (upstream)

## How to run

```bash
# Build the adapter
cd /home/jac/repos/jackal
npm run build:agent

# Run the shell (interactive terminal required)
cd agent-next
./jackal.sh
```

## File map

```
agent-next/
├── dist/                  # compiled adapter
├── src/                   # headless adapter (TS)
├── templates/
│   ├── shell.cl.jac       # Ink shell UI
│   └── jac_pi_facade.mjs  # Reference adapter (now inlined in jac-ink shim)
└── bin/
    └── jackal_shell.jac   # jac tui launcher

~/repos/jac-tui/
└── jac-ink/               # compiler + @jac/pi shims
    └── jac_ink/plugin/cli.jac  # patched: Vite bypass + Pi import injection
```
