# Jackal — Required Features

Features needed for `./jackal.sh` to be a daily-usable Jac coding agent.

**Not in scope for v1:** full IDE, replacing the Jac compiler/LSP, hosting models, cloud deployment.

> **Glossary:** **jac-ink** is a Jac plugin in the separate [`jac-tui`](~/repos/jac-tui) repo. It compiles `.cl.jac` UI code into an Ink + React terminal app via `jac tui`. It is the UI compiler/launcher — not the agent brain. See [JAC-TUI.md](./JAC-TUI.md) for what belongs in jac-tui vs this repo.

> **Agent workflow:** Do not modify jac-ink, jaclang, jac-client, or write/edit shim scripts in this repo. When a framework or plugin change is needed, document it and **hand off to the human** (see [`AGENTS.md`](../AGENTS.md) § Runtime architecture notes).

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
| Smoke / CI path | `./jackal.sh --check` or `jackal run --check` | Done |

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
| Tool timeline UI | Running/done tool rows inline in chat transcript | Done |
| Tool detail in UI | Name, status, truncated input/result, duration | Done |
| Notifications | Extension `notify()` surfaced in shell | Done |
| Help panel | `/help` command reference | Done |
| `/compact` | Context compaction command with auto-compact at threshold | Done (mechanical summary + auto-compact + preview/restore) |
| SIGINT / shutdown UX | Clear messaging on abort vs exit | Done |

---

## 3. Agent capabilities

### Core tools
| Tool | Purpose | Status |
|------|---------|--------|
| `read` | Read file contents | Done |
| `write` | Create / overwrite files | Done |
| `edit` | Exact text replacement | Done |
| `bash` | Run shell commands | Done |
| `glob` | Find files by pattern | Done |

### Jac toolchain tools
| Tool | Purpose | Status |
|------|---------|--------|
| `jac_cli` | Run any `jac` CLI command | Done |
| `jac_check` | Structured diagnostics | Done |
| `jac_fix` | Bounded check-format-check loop | Done |
| `jac_test` | Run tests with diagnostic parsing | Done |
| `jac_format` | Format .jac files | Done |
| `jac_run` | Execute .jac files with output capture | Done |
| `jac_doctor` | Jac environment detection | Done |
| `jac_create` | Run `jac create` templates | Done |
| `jac_list_templates` | List available templates | Done |

### LSP tools
| Tool | Purpose | Status |
|------|---------|--------|
| `diagnostics` | Get compiler diagnostics for files | Done |
| `hover` | Get type info / context at position | Done |
| `definition` | Find symbol declarations | Done |
| `references` | Find all symbol references | Done |

### Task tools
| Tool | Purpose | Status |
|------|---------|--------|
| `create_task` | Create tasks for multi-step work | Done |
| `update_task` | Update task status | Done |
| `list_tasks` | List tasks with filters | Done |
| `delete_task` | Delete tasks by ID | Done |

### Agent tools
| Tool | Purpose | Status |
|------|---------|--------|
| `agent` | Delegate to subagent (scout, architect, implementer) | Done |
| `mermaid` | Render Mermaid diagram as ASCII | Done |
| `compact_context` | Context compaction (stub) | Partial |

### MCP tools
Any tools exposed by `jac mcp` are auto-discovered and available (validate_jac, search_docs, get_ast, etc.)

### System & infrastructure
| Feature | Status |
|---------|--------|
| System prompt with skill catalog | Done |
| `.jackal` project config | Done |
| MCP lazy connect after boot | Done |
| Tool event bridge | Done |
| Dev modes (normal/auto-accept/yolo/plan) | Done |
| Tool approval queue | Done |
| @file mentions + line ranges | Done |
| !command inline execution | Done |
| Auto-compact at threshold | Done |
| Session retention pruning | Done |
| Checkpointing | Done |
| Subagents + chains | Done |
| Custom commands | Done |
| Non-interactive `jackal run` | Done |

---

## 4. Jackal-specific workflows

Port into the Jackal runtime (`src/` + `templates/shell.cl.jac`).

| Feature | Description | Status |
|---------|-------------|--------|
| `.jackal` project config | Read `autocheck`, `verbose`, `plan`, `autoCompact`, `sessions` from project root | Done |
| `/jac-doctor` | Detect Jac install, project type, MCP, `.jac` files | Done |
| `/jac-check` | Run `jac check`, display diagnostics | Done |
| Autocheck on edit | Re-validate `.jac` after write/edit when `autocheck` enabled | Done |
| `/fix` | Check → patch → re-check loop (capped retries) | Done |
| `/create` | Wrapper around `jac create` templates | Done |
| Skills on demand | Load `pi/skills/*/SKILL.md` when task matches | Done (skill index in system prompt, agent reads via read tool) |
| Prompt templates | Reusable prompts from `pi/prompts/` | Done (explain, osp, convert-python, review-idioms, explain-walker, explain-error, explain-graph) |

**Already ported into Jackal runtime (fully implemented):**

| Feature | Notes |
|---------|-------|
| Plan mode | Tool gating, read-only exploration phase |
| Subagents | scout / architect / implementer chains |
| `/osp` | OSP graph modeling workflow |
| `/jac explain` | Explain file/walker/error/graph variants |
| `/init` | Project analyzer → AGENTS.md generation |
| Dev modes | normal/auto-accept/yolo/plan with Shift+Tab cycling |
| Tool approval | Pending approval queue with approve/reject |
| Checkpoints | Create/list/load/delete with file snapshots |
| Task management | Agent tools + slash commands |
| Custom commands | `.jackal/commands/*.md` with template expansion |
| Non-interactive `jackal run` | --mode, --plain flags |
| Auto-compact | Threshold-based, mechanical summary |
| Session retention | Configurable maxCount + retentionDays |

**Still to implement (shell/TUI wiring):**

*(No remaining features — all runtime capabilities are implemented. Shell/TUI wiring is the remaining work.)*

---

## 5. Build, compile, and launch

| Feature | Description | Status |
|---------|-------------|--------|
| TS adapter build | `npm run build:agent` → `dist/` | Done |
| jac-ink compile | `jac tui shell.cl.jac` → `.jac/tui/` (via `./jackal.sh`) | Done |
| Adapter wiring | `@jac/pi` → headless adapter (`JACKAL_AGENT_DIST`); owned by **jac-ink** | Partial — human maintains plugin |
| `./jackal.sh` launch | Build + compile + run Ink shell | Done |
| Fast TUI boot | Lazy MCP after first frame (`scheduleMcpConnect`) | Done |
| Unified launch entrypoints | `bin/jackal_shell.jac` / `npm run start:agent-shell` same as `jackal.sh` | Done |
| Auth symlink | `pi/auth.json` → `~/.pi/agent/auth.json` (provider credentials) | Done |

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

Run before calling Jackal v1 done:

- [x] `./jackal.sh` boots in interactive terminal (TUI visible quickly)
- [x] MCP connects in background; status bar reflects connection state
- [x] `/login` + `/model` + successful prompt on chosen model
- [x] 3+ prompt/response cycles with streaming
- [x] Restart shell → transcript and model restored
- [x] `/clear` → empty transcript and empty agent memory
- [x] Agent reads a file and summarizes it
- [x] Agent runs `jac check` via MCP or bash
- [x] Tool rows appear during multi-tool turn
- [x] `/jac-check` surfaces compiler diagnostics
- [x] Editing a `.jac` file triggers autocheck (when enabled)
- [x] Auto-compact triggers at threshold
- [x] Skill catalog in system prompt
- [x] `/init` generates AGENTS.md
- [x] `/jac explain` works for all variants

---

## 8. Success definition

Jackal v1 is **done** when `./jackal.sh`:

1. Boots a reliable Ink shell quickly, with auth, model selection, and session restore
2. Runs an agent with file + bash + Jac MCP tools under `pi/SYSTEM.md`
3. Supports `/jac-check` and autocheck-on-edit for Jac projects
4. Has a clear path to port plan mode, subagents, and LSP without relying on any alternate launcher
5. Auto-compact keeps long sessions running smoothly
6. Skill catalog and `/jac explain` provide Jac-specific intelligence
7. `/init` bootstraps project documentation

---

## Related docs

- [PLAN.md](./PLAN.md) — phase breakdown (build pipeline, shell, integration)
- [REMAINING_TUI_PLAN.md](./REMAINING_TUI_PLAN.md) — Ink milestone checklist (M1–M6)
- [JAC-TUI.md](./JAC-TUI.md) — jac-ink / jac-tui handoff checklist
- [../../AGENTS.md](../AGENTS.md) — agent rules (framework changes → human)
- [../README.md](../README.md) — run instructions and architecture overview
