# Implementation Plan (Jackal repo)

## Scope

Implement the coding agent **in this repo**. **UI renderer:** jac-ink (external jac-tui repo, human-maintained). **Agent runtime:** headless adapter in `src/`.

See [`AGENTS.md`](../../AGENTS.md) and [JAC-TUI.md](./JAC-TUI.md): agents do **not** edit jac-ink, jaclang, or shim scripts. Hand framework changes to the human.

## Phases

### Phase 0 — Headless runtime boot ✅
- `JackalAgentSession` boots via `pi-agent-core`
- Events stream (`agent_start`, `message_update`, `agent_end`, etc.)
- `runNextAgentSmoke()` verifies end-to-end in `/next-agent-smoke`

### Phase 1 — CLI dependency wiring ✅ (jac-tui repo — human)
- `@jac/pi` import detection and shim emission in jac-ink
- `PI_DEFAULT_DEPS` map, `--with_pi`/`--no_pi` flags
- Package.json injection with Pi SDK deps
- See `~/repos/jac-tui/docs/pi-interop-progress.md`

### Phase 2 — Store + event bridge ✅
- `AgentStore` — immutable snapshot, subscriber pattern
- `bridgeEvents()` — session events → store mutations
- `createNextAgent()` factory with actions

### Phase 3 — Extension UI context ✅
- `InkExtensionUIContext` — headless ExtensionUIContext for Ink shell
- notify, dialogs (select/confirm/input/editor as Promises)
- Unsupported host-injected component factories degrade with structured warnings

### Phase 4 — Auth + model picker ✅
- `AuthFlowStore` state machine
- `AuthActions` — pi-ai OAuth / API keys
- `createNextAgent()` exposes authFlow + authActions + setModel

### Phase 5 — Headless adapter hardening ✅
- Adapter proven for streaming, auth, persistence (chat-only until tools wired)
- Features to expose in `shell.cl.jac`

### Phase 6 — Ink shell (current — jackal repo)
- `shell.cl.jac` wired to `@jac/pi` hooks
- `./jackal.sh` compile + run path
- Remaining: session bugs, tools, MCP, Jackal workflows ([FEATURES.md](./FEATURES.md))

### Phase 7 — Integration (jackal repo + human handoffs)
- `./jackal.sh` as the sole supported launch path
- Tools + Jac MCP in `src/` (lazy-load MCP after TUI render)
- Request from human: jac-ink adapter injection, any compiler fixes ([JAC-TUI.md](./JAC-TUI.md))

## Acceptance

- End-to-end prompt loop runs via **jac-ink** + `./jackal.sh`
- Auth flow works for OAuth + API-key providers
- Ink TUI renders streaming text, tool calls, messages
- Agent can read/edit/run bash + Jac MCP (when Phase 7 complete)
- Framework gaps documented for human — not patched by agents in jac-tui/jaclang
