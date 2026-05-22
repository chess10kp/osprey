# Implementation Plan (Jackal repo)

## Scope
Implement the new coding agent in this repo. **UI renderer:** jac-ink (jac-tui repo).
**Agent runtime:** headless Pi SDK adapter in `agent-next/src/`.

## Phases

### Phase 0 — Headless runtime boot ✅
- `createAgentSession()` boots in-process
- Events stream (`agent_start`, `message_update`, `agent_end`, etc.)
- `runNextAgentSmoke()` verifies end-to-end in `/next-agent-smoke`

### Phase 1 — CLI dependency wiring ✅ (jac-tui repo)
- `@jac/pi` import detection and shim emission in jac-ink
- `PI_DEFAULT_DEPS` map, `--with_pi`/`--no_pi` flags
- Package.json injection with Pi SDK deps
- See `~/repos/jac-tui/docs/pi-interop-progress.md`

### Phase 2 — Store + event bridge ✅
- `AgentStore` — immutable snapshot, subscriber pattern
- `bridgeEvents()` — Pi session events → store mutations
- `createNextAgent()` factory with actions

### Phase 3 — Extension UI context ✅
- `InkExtensionUIContext` — headless ExtensionUIContext for Ink shell
- notify, dialogs (select/confirm/input/editor as Promises)
- Unsupported host-injected component factories degrade with structured warnings
- `session.bindExtensions()` wired in adapter

### Phase 4 — Auth + model picker ✅
- `AuthFlowStore` state machine
- `AuthActions` — AuthStorage/ModelRegistry
- `createNextAgent()` exposes authFlow + authActions + setModel

### Phase 5 — Headless adapter hardening ✅
- Adapter proven end-to-end (streaming, auth, tools, persistence)
- Features to port into `shell.cl.jac`

### Phase 6 — jac-ink shell (current)
- Port `shell.cl.jac` to full Ink app wired to adapter / `@jac/pi`
- `jac tui templates/shell.cl.jac --with_pi --install --run`
- jac-ink Phase 2: `jac_pi_adapter.mjs` in jac-tui repo

### Phase 7 — Integration
- `jackal.sh` / `/jackal-shell` launch jac-ink path
- Extension loading from project `.pi/extensions/`
- MCP server auto-discovery

## Acceptance
- End-to-end prompt loop runs via **jac-ink**
- Extension hooks work with explicit capability boundaries
- Auth flow works for OAuth + API-key providers
- Ink TUI renders streaming text, tool calls, messages
- Changes validated with Jac/Pi checks and `jac tui` smoke tests
