# Agent-Next — Required Features

Features needed for agent-next to replace the default `./jackal.sh` path as a daily-usable Jac coding agent.

**Not in scope for v1:** full IDE, replacing the Jac compiler/LSP, hosting models, cloud deployment.

> **Glossary:** **jac-ink** is a Jac plugin in the separate [`jac-tui`](~/repos/jac-tui) repo. It compiles `.cl.jac` UI code into an Ink + React terminal app via `jac tui`. It is the UI compiler/launcher — not the agent brain. See [JAC-TUI.md](./JAC-TUI.md) for what belongs in jac-tui vs this repo.

> **Agent workflow:** Do not modify jac-ink, jaclang, jac-client, or write/edit shim scripts in this repo. When a framework or plugin change is needed, document it and **hand off to the human** (see [`AGENTS.md`](../../AGENTS.md) § agent-next migration notes).

---

## 1. Runtime foundation

These must work before anything else is useful.

| Feature | Description | Status |
|---------|-------------|--------|
| Headless adapter boot | `createNextAgent()` wires store, bridge, auth, session | Done |
| Immutable agent store | Single source of truth for Ink via `AgentStore` + `bridgeEvents` | Done |
| pi-agent-core loop | `JackalAgentSession` runs prompt/stream/abort via `Agent` | Done (chat-only) |
| pi-ai auth + models | OAuth, API keys, model picker; shared `jackal/auth.json` | Done |
| Session persistence | Disk-backed `.jackal/sessions/latest.json` | Partial |
| Session restore (messages) | Reload transcript on startup | Done |
| Session restore (model) | Apply persisted provider/model on boot | Done |
| `/clear` / `/new` | Reset store, session file, **and** agent message memory | Done |
| Graceful dispose | `/exit`, Ctrl+C cleanup without corrupting session | Done |
| Smoke / CI path | Non-interactive verification of adapter boot | Missing |

---

## 2. Ink shell (jac-ink TUI)

UI lives in `templates/shell.cl.jac`; hooks via `@jac/pi` (resolved by jac-ink at compile time).

| Feature | Description | Status |
|---------|-------------|--------|
| Boot / error screen | Show adapter boot state and failures | Done |
| Welcome banner | First-run intro | Done |
| Status bar | Phase, model, provider, session name, counts | Done |
| Message transcript | User + assistant messages with scrollback | Done |
| Streaming display | Live assistant token stream | Done (needs real-credential verification) |
| Multiline input | `/multiline`, Ctrl+D to send | Done |
| Slash command routing | `/help`, `/login`, `/model`, `/abort`, etc. | Done |
| Slash completions | Command + `@file` autocomplete | Done |
| Auth overlays | Provider picker, browser OAuth, API key, model picker | Done |
| Auth error display | Inline errors with retry path | Done |
| Dialog overlays | Select / confirm / input from extension UI context | Done |
| Tool timeline UI | Running/done tool rows in transcript | Done (UI only; no tools fire yet) |
| Tool detail in UI | Name, status, truncated input/result, duration | Missing |
| Notifications | Extension `notify()` surfaced in shell | Done |
| Help panel | `/help` command reference | Done |
| `/compact` | Context compaction command | Partial (basic session compaction + stub tool) |
| SIGINT / shutdown UX | Clear messaging on abort vs exit | Partial |

---

## 3. Agent capabilities (blockers)

Without these, agent-next is chat-only and not a coding agent.

| Feature | Description | Status |
|---------|-------------|--------|
| Jackal system prompt | Load `jackal/SYSTEM.md` at session boot | Done |
| Read tool | Read project files | Done |
| Write tool | Create / overwrite files | Done |
| Edit tool | Targeted file edits | Done |
| Bash tool | Run shell commands (`jac`, `git`, etc.) | Done |
| Jac MCP | Spawn `jac mcp`; expose validate/run/docs/format/etc. | Partial (jac CLI proxy tool, full MCP tool surface still missing) |
| Tool event bridge | Map tool start/end → store (bridge exists; needs tools) | Done |
| Project CWD | Respect `JACKAL_AGENT_CWD` for tools and sessions | Done |
| Working directory safety | Sensible defaults, visible command execution | Missing |

---

## 4. Jackal-specific workflows

Port from classic extension without requiring full `pi-coding-agent`.

| Feature | Description | Status |
|---------|-------------|--------|
| `.jackal` project config | Read `autocheck`, `verbose`, `plan`, etc. from project root | Partial (autocheck supported) |
| `/jac-doctor` | Detect Jac install, project type, MCP, `.jac` files | Partial |
| `/jac-check` | Run `jac check`, display diagnostics | Partial |
| Autocheck on edit | Re-validate `.jac` after write/edit when `autocheck` enabled | Done |
| `/fix` | Check → patch → re-check loop (capped retries) | Partial (tool-driven check/format/check loop) |
| `/create` | Wrapper around `jac create` templates | Partial (tool-driven wrapper) |
| Skills on demand | Load `skills/*/SKILL.md` when task matches | Missing |
| Prompt templates | Reusable prompts from `prompts/` | Missing |

**Defer to classic `./jackal.sh --pi` until ported:**

| Feature | Notes |
|---------|-------|
| Plan mode | Tool gating, read-only exploration phase |
| Subagents | scout / architect / implementer via `pi-subagents` |
| LSP tools | diagnostics, hover, rename via `pi-lsp-extension` |
| Mermaid rendering | `pi-mermaid` ASCII diagrams |
| `/commit`, `/refactor`, `/osp` | Extension slash commands |

---

## 5. Build, compile, and launch

| Feature | Description | Status |
|---------|-------------|--------|
| TS adapter build | `npm run build:agent` → `dist/` | Done |
| jac-ink compile | `jac tui shell.cl.jac` → `.jac/tui/` (via `./jackal.sh`) | Done |
| Adapter wiring | `@jac/pi` → headless adapter (`JACKAL_AGENT_DIST`); owned by **jac-ink** | Partial — human maintains plugin |
| `./jackal.sh` default path | Build + compile + run Ink shell | Done |
| `./jackal.sh --pi` fallback | Classic Pi + Jackal extension | Done |
| Unified launch entrypoints | `bin/jackal_shell.jac` / `npm run start:agent-shell` same as `jackal.sh` | Missing |
| Auth symlink | `jackal/auth.json` → `~/.pi/agent/auth.json` | Done |
| `PI_CODING_AGENT_DIR` | Point at `jackal/` for auth + future config | Done |

---

## 6. Upstream and maintenance (human-owned)

Jackal agents **do not implement** items in this section. Record the requirement and hand off to the human.

| Feature | Description | Status |
|---------|-------------|--------|
| jac-ink Vite bypass | Plain `ClientBundleBuilder` for Node/Ink | Done in jac-ink (human) |
| `@jac/pi` import injection | jac-ink adds virtual import when hooks detected | Done in jac-ink (human) |
| `.cl.jac` stem fix | Compiled JS module name correct | Done in jaclang/jac_client (human) |
| Adapter injection in jac-ink | Formal `--adapter` / config; no shim copy workaround | Missing — request from human |
| Document framework patches | What jac-ink/jaclang changes are required | Partial |
| Orphaned component cleanup | `templates/components/*.cl.jac` unused vs monolithic shell | Open (jackal repo OK) |

---

## 7. Verification checklist

Run before calling agent-next v1 done:

- [ ] `./jackal.sh` boots in interactive terminal
- [ ] `/login` + `/model` + successful prompt on chosen model
- [ ] 3+ prompt/response cycles with streaming
- [ ] Restart shell → transcript and model restored
- [ ] `/clear` → empty transcript and empty agent memory
- [ ] Agent reads a file and summarizes it
- [ ] Agent runs `jac check` via MCP or bash
- [ ] Tool rows appear during multi-tool turn
- [ ] `/jac-check` surfaces compiler diagnostics
- [ ] Editing a `.jac` file triggers autocheck (when enabled)
- [ ] `./jackal.sh --pi` still works as fallback

---

## 8. Success definition

Agent-next v1 is **done** when the default `./jackal.sh` path:

1. Boots a reliable Ink shell with auth, model selection, and session restore
2. Runs an agent with file + bash + Jac MCP tools under `jackal/SYSTEM.md`
3. Supports `/jac-check` and autocheck-on-edit for Jac projects
4. Keeps `./jackal.sh --pi` available for plan mode, subagents, and LSP until ported

---

## Related docs

- [PLAN.md](./PLAN.md) — phase breakdown (build pipeline, shell, integration)
- [REMAINING_TUI_PLAN.md](./REMAINING_TUI_PLAN.md) — Ink milestone checklist (M1–M6)
- [JAC-TUI.md](./JAC-TUI.md) — jac-ink / jac-tui handoff checklist
- [../../AGENTS.md](../../AGENTS.md) — agent rules (framework changes → human)
- [../README.md](../README.md) — run instructions and architecture overview
