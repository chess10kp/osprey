# Plan: Jackal Agent-Next to Working TUI

See also:
- **[FEATURES.md](./FEATURES.md)** — full feature checklist with status
- **[JAC-TUI.md](./JAC-TUI.md)** — jac-ink / jac-tui work (human-owned)
- **[../../AGENTS.md](../../AGENTS.md)** — agents do not edit jac-ink shims or plugin code; hand framework changes to the human

## Agent workflow (all phases)

**In this repo:** `agent-next/src/`, `agent-next/templates/shell.cl.jac`, `jackal.sh`, Jackal extensions/skills, docs.

**Not in this repo (human maintains):** `~/repos/jac-tui/jac-ink`, jaclang/jac_client site-packages, any `jac_pi_runtime_shim.mjs` or similar shim scripts. When compilation or `@jac/pi` wiring breaks, document the symptom and recommended fix for the human — do not patch the plugin yourself.

## Current State (2026-05-22)

What works (verified, runs):
- `src/adapter.ts` — `createNextAgent()` boots a Jackal session (`pi-agent-core`) with auth, store, bridge
- `src/store.ts` — immutable snapshot store
- `src/bridge.ts` — Pi events → store mutations
- `src/ui-context.ts` — headless ExtensionUIContext (dialogs, notify)
- `src/auth-flow.ts` — login state machine
- `src/auth-actions.ts` — drives `JackalAuth` / `JackalModels` (pi-ai)
- `src/completions.ts` — slash-command autocomplete

What works in jac-ink (`~/repos/jac-tui`) — **maintained by human, not jackal agents**:
- **jac-ink bypasses Vite** — uses plain `ClientBundleBuilder` for Ink apps
- **`@jac/pi` import injection** — detects hook usage and adds the import
- **`jac_pi_runtime_shim.mjs`** — emitted by jac-ink; boots headless adapter via `JACKAL_AGENT_DIST`
- `agent-next/jac.toml` declares `pi-agent-core` + `pi-ai` (no `pi-coding-agent`)

What runs:
- `./jackal.sh` → `jac tui` compile + run (interactive terminal required)
- Ink renders the shell UI from `shell.cl.jac`

## Framework changes (human-owned)

These live outside the jackal repo. Agents record requirements; the human applies fixes.

1. **`jac_client/.../compiler.impl.jac`** — `.cl.jac` stem → correct `.js` module name
2. **`jaclang/.../client_bundle.impl.jac`** — skip `@jac/pi` in `_process_imports` (virtual import for jac-ink)
3. **`jac-tui/jac-ink/.../cli.jac`** — Vite bypass, `@jac/pi` rewrite, adapter shim emission

See [JAC-TUI.md](./JAC-TUI.md) for the full handoff checklist.

## Phases

### Phase A: Build Pipeline ✅
Compiled `agent-next/src/*.ts` → `agent-next/dist/*.js`

### Phase B: Headless adapter ✅
Store, bridge, auth, ExtensionUIContext — no rendering layer

### Phase C: jac-ink compilation pipeline ✅
`./jackal.sh` compiles via jac-ink and runs (adapter wiring via jac-ink shim — human-owned)

### Phase D: Interactive shell (current)
**Goal:** Full interactive prompt/response through the Ink shell

Remaining:
1. Test with real Pi credentials (auth flow)
2. Verify streaming text renders correctly
3. Verify tool execution timeline
4. Test /login, /model, /abort commands
5. Test multiline input

### Phase E: Integration
1. `jackal.sh` / `jackal_shell.jac` launch `jac tui` (jackal repo)
2. Request from human: formal adapter injection in jac-ink (drop any shim copy workarounds)

## How to run

```bash
# From repo root (interactive terminal required)
npm run build:agent
./jackal.sh
```

## File map

```
agent-next/
├── dist/                  # compiled adapter (jackal agents OK)
├── src/                   # headless adapter (jackal agents OK)
├── templates/
│   └── shell.cl.jac       # Ink shell UI (jackal agents OK)
└── bin/
    └── jackal_shell.jac   # jac tui launcher

~/repos/jac-tui/
└── jac-ink/               # compiler + @jac/pi shim (human only)
    └── jac_ink/plugin/cli.jac
```
