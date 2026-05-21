# Implementation Plan (Jackal repo)

## Scope
Implement the new coding agent in this repo (not in external plugin repos).

## Phases

### Phase 0 — Headless runtime boot ✅
- `createAgentSession()` boots in-process
- Events stream (`agent_start`, `message_update`, `agent_end`, etc.)
- `runNextAgentSmoke()` verifies end-to-end in `/next-agent-smoke`

### Phase 1 — CLI dependency wiring ✅
- `@jac/pi` import detection and shim emission in `jac-tui`
- `PI_DEFAULT_DEPS` map, `--with_pi`/`--no_pi` flags
- Package.json injection with Pi SDK deps

### Phase 2 — Store + event bridge ✅
- `AgentStore` — immutable snapshot, subscriber pattern
- `bridgeEvents()` — Pi session events → store mutations
- `createNextAgent()` factory with actions

### Phase 3 — Extension UI context ✅
- `InkExtensionUIContext` — full headless ExtensionUIContext
- notify, dialogs (select/confirm/input/editor as Promises)
- Unsupported methods degrade with structured warnings
- `session.bindExtensions()` wired in adapter

### Phase 4 — Auth + model picker ✅
- `AuthFlowStore` state machine (provider picker → OAuth → model picker)
- `AuthActions` — drives AuthStorage/ModelRegistry through state machine
- OAuth callbacks (onAuth/onPrompt/onManualCodeInput/onSelect) piped through
- API-key login flow
- `createNextAgent()` exposes authFlow + authActions + setModel

### Phase 5 — Ink TUI shell ✅
- `agent-next/templates/shell.mjs` — self-contained Ink shell
- Header, MessageList, StatusBar, input components
- Keyboard handling (type, enter, escape to abort)
- `/jackal-shell` command scaffolds temp project + deps
- Graceful shutdown on SIGINT/SIGTERM

### Phase 6 — Hardening (next)
- Multi-line input support (Shift+Enter or colon-prefix)
- Scrollback / message pagination
- Tool call rendering (name, args, result, duration)
- Auth overlay rendering (provider picker, model picker)
- Diff rendering for file edits
- Command palette (/help, /model, /login, /logout, /clear)
- Session persistence (disk-backed SessionManager)

### Phase 7 — Integration
- Wire into `jac tui` command pipeline
- `jackal.sh` launcher integration
- Extension loading from project `.pi/extensions/`
- MCP server auto-discovery

## Acceptance
- End-to-end prompt loop runs from Jackal host
- Extension hooks work with explicit capability boundaries
- Auth flow works for OAuth + API-key providers
- TUI renders streaming text, tool calls, messages
- Changes are validated with Jac/Pi checks and runtime smoke tests
