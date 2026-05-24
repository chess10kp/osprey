# Plan: Jackal to Working TUI

See also:
- **[FEATURES.md](./FEATURES.md)** — full feature checklist with status
- **[JAC-TUI.md](./JAC-TUI.md)** — jac-ink / jac-tui work (human-owned)
- **[../AGENTS.md](../AGENTS.md)** — agents do not edit jac-ink shims or plugin code; hand framework changes to the human

## Agent workflow (all phases)

**In this repo:** `src/`, `templates/shell.cl.jac`, `jackal.sh`, skills under `pi/skills/`, docs.

**Not in this repo (human maintains):** `~/repos/jac-tui/jac-ink`, jaclang/jac_client site-packages, any `jac_pi_runtime_shim.mjs` or similar shim scripts. When compilation or `@jac/pi` wiring breaks, document the symptom and recommended fix for the human — do not patch the plugin yourself.

## Current State (2026-05-24)

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
- `src/jac.toml` declares `pi-agent-core` + `pi-ai` (no `pi-coding-agent`)

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
Compiled `src/*.ts` → `dist/*.js`

### Phase B: Headless adapter ✅
Store, bridge, auth, ExtensionUIContext — no rendering layer

### Phase C: jac-ink compilation pipeline ✅
`./jackal.sh` compiles via jac-ink and runs (adapter wiring via jac-ink shim — human-owned)

### Phase D: Interactive shell ✅
**Goal:** Full interactive prompt/response through the Ink shell — complete (P0–P8).

### Phase E: Integration
1. `jackal.sh` / `jackal_shell.jac` launch `jac tui` (jackal repo)
2. Request from human: formal adapter injection in jac-ink (drop any shim copy workarounds)

### Remaining polish (nanocoder gaps)

See [NANOCODER-PARITY.md](./NANOCODER-PARITY.md): markdown text wrapping, rich tool approval dialog, `.gitignore`-aware file search, task/checkpoint Ink overlays.

## How to run

```bash
# From repo root (interactive terminal required)
npm run build:agent
./jackal.sh
```

## File map

```
jackal/
├── dist/                  # compiled adapter (public API: dist/index.js)
├── src/                   # headless adapter — organized by domain
│   ├── index.ts           # public exports + CLI entry
│   ├── core/              # adapter, store, bridge, ui-context
│   ├── auth/              # credentials, login flow, auth actions
│   ├── session/           # session manager, agent session, auto-compact
│   ├── agent/             # tools, MCP, dev-mode, tool approval
│   ├── config/            # .jackal project config loader
│   ├── jac/               # jac CLI, doctor, workflows, LSP
│   ├── workflow/          # tasks, checkpoints, context input/usage
│   ├── orchestration/     # subagents, chains, frontmatter
│   ├── project/           # project init, file explorer, skills
│   ├── ui/                # slash-command completions
│   ├── render/            # mermaid ASCII renderer
│   └── cli/               # headless `jackal run` CLI
├── templates/
│   └── shell.cl.jac       # Ink shell UI
└── bin/
    └── jackal_shell.jac   # jac tui launcher

~/repos/jac-tui/
└── jac-ink/               # compiler + @jac/pi shim (human only)
    └── jac_ink/plugin/cli.jac
```
