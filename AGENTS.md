# Jackal — Agent onboarding (read this first)

Jac-native terminal coding agent. **Ink TUI** (`templates/shell.cl.jac`) + **headless TypeScript runtime** (`src/` → `dist/`). Does **not** use the legacy Pi extension shell (`pi/extensions/` was removed).

---

## Rules for agents working in this repo

1. **Commit** after each feature or bugfix (unless the user says otherwise).
2. **Do not modify** `jac-ink`, `jaclang`, or `jac-client`. Do **not** write or edit compile-pipeline shims in jac-tui.
3. **Do not edit** `templates/jackal_agent_facade.mjs` as a long-term fix — it is copied into `.jac/tui/` by `jackal.sh`; real hook naming belongs in jac-ink upstream. Short-term Jackal-only facade tweaks in-repo are acceptable when the human agrees.
4. **Framework/plugin gaps** → stop, document symptom + owning repo + minimal recommended fix for the **human** (see [Human handoff](#human-handoff-jac-ink--jaclang)).
5. **Work here:** `src/`, `templates/shell.cl.jac` + `templates/components/`, `jackal.sh`, `scripts/*.mjs` (TUI postprocess only), `pi/skills/`, `pi/prompts/`, docs, tests.

---

## Quick start (dev)

```bash
npm install              # applies patch-package
npm run build:agent      # tsc → dist/
./jackal.sh              # compile shell + run Ink (TTY required)

# CI / headless (no jac-ink, no TTY)
npm run check            # or ./jackal.sh --check (TS adapter smoke)
npm run check:jac        # lib/jac toolchain + npm agent loop (migration CI)
./jackal.sh run "prompt" # headless one-shot
```

| Command | What it does |
|---------|----------------|
| `npm run build:agent` | Compile `src/` → `dist/index.js` |
| `./jackal.sh` | Build adapter if needed, `jac tui templates/shell.cl.jac`, postprocess, run `.jac/tui/runner.mjs` |
| `./jackal.sh --check` | Smoke: boot session, send message, wait for `agent_end` |
| `./jackal.sh run "…"` | Headless CLI (`src/cli/run.ts`) |
| `./jackal.sh --mode plan` | Boot in plan mode (also `JACKAL_MODE`) |
| `npm test` | Vitest: `tests/adapter/`, `tests/session/` |
| `npm run test:tui` | Ink component tests (precompiled fixtures) |

**Requirements:** Node.js, `jac` CLI (+ `jac mcp` for MCP tools), **jac-ink** for TUI compile (`jac tui`). Install: `./scripts/setup-jac-ink.sh`. Non-interactive Ink fails without a TTY.

---

## Architecture (one picture)

```
User terminal
    │
    ▼
jackal.sh
    ├─ build dist/index.js (tsc)
    ├─ jac tui templates/shell.cl.jac → .jac/tui/
    ├─ postprocess: facade, sed hook renames, fix-tui-module.mjs, …
    └─ node .jac/tui/runner.mjs
            │
            │  @jac/pi hooks (jackal_agent_facade.mjs)
            ▼
        createNextAgent(cwd)  ← dist/index.js
            │
            ├─ JackalAgentSession  (pi-agent-core Agent loop)
            ├─ bridgeEvents()      → AgentStore (immutable snapshots)
            ├─ JackalUIContext     (dialogs, notify)
            └─ AuthFlowStore + AuthActions
            │
            ▼
        shell.cl.jac React/Ink UI subscribes to store + UI context
```

**Single source of truth for UI state:** `AgentStore` (`src/core/store.ts`). Only `bridge.ts` mutates it after boot (plus approval callbacks). Ink reads snapshots via facade hooks (`useJackalSession`, `useTranscript`, …).

**Agent brain:** `JackalAgentSession` (`src/session/agent-session.ts`) wraps `@earendil-works/pi-agent-core` `Agent` + `@earendil-works/pi-ai` models/auth. Not `pi-coding-agent` — embedded adapter only.

---

## Source code shape (~13,200 LOC across 56 TS files)

Largest files (top 10 by LOC):

| File | LOC | Role |
|------|-----|------|
| `src/jac/jac-bridge.ts` | 1012 | Sync/async Python toolchain bridge |
| `src/session/agent-session.ts` | 1000 | **THE agent loop** — tools, MCP, LSP, autocheck, compaction |
| `src/core/adapter.ts` | 735 | `createNextAgent()` — wires store, session, bridge, auth, `actions.*` |
| `src/agent/tools.ts` | 703 | Core tool definitions: read, write, edit, bash, glob, jac_*, LSP, mermaid |
| `src/project/skills.ts` | 517 | SKILL.md discovery, loading, formatting |
| `src/render/mermaid-render.ts` | 505 | Mermaid → ASCII renderer |
| `src/jac/lsp-tools.ts` | 418 | LSP tool functions (diagnostics, hover, definition, references) |
| `src/project/project-init.ts` | 394 | Project analysis for `/init` |
| `src/core/store.ts` | 392 | Immutable `AgentSnapshot` store |
| `src/agent/session-permissions.ts` | 388 | Pattern-based tool permission engine |

### `src/` directory structure

```
src/
├── index.ts                  # Public API re-exports (everything)
├── cli/
│   └── run.ts (312)          # Headless `jackal run` entry
├── core/
│   ├── adapter.ts (735)      # createNextAgent() + actions.* bag
│   ├── store.ts (392)        # AgentSnapshot, immutable store
│   ├── bridge.ts (314)       # Session events → store mutations
│   ├── ui-context.ts (170)   # Dialog/notification state for Ink
│   ├── agent-busy.ts (14)    # Busy detection for queue/abort
│   └── tool-summary.ts (177) # One-line tool labels in transcript
├── session/
│   ├── agent-session.ts (1000) # Agent loop, tools, MCP, LSP, compaction
│   ├── session.ts (368)        # Disk persistence, 30s auto-save
│   ├── session-index.ts (304)  # Session list, resume, retention prune
│   ├── outbound-queue.ts (28)  # Queue messages while agent busy
│   ├── auto-compact.ts (144)   # Threshold compaction trigger
│   └── llm-compact.ts (50)     # LLM-based compaction
├── agent/
│   ├── tools.ts (703)          # Core tool definitions
│   ├── dev-mode.ts (209)       # Mode logic + read-only tool blocks
│   ├── session-permissions.ts (388) # Pattern-based permission engine
│   ├── tool-approval.ts (84)   # Destructive tool approval queue
│   ├── subagent-approval.ts (81) # Subagent approval queue
│   ├── mcp-client.ts (132)     # Stdio MCP to `jac mcp`
│   ├── mcp-schema.ts (73)      # TypeBox MCP input schema adapter
│   ├── system-prompt.ts (31)   # Loads SYSTEM.md + skill index
│   ├── task-tools.ts (235)     # Task CRUD tool definitions
│   ├── web-tools.ts (302)      # web_search, web_fetch tool defs
│   ├── agent-tool.ts (80)      # Subagent tool factory
│   └── tool-output-limit.ts (95) # 50KB tool output truncation
├── auth/
│   ├── auth.ts (183)           # pi-ai OAuth/API keys client
│   ├── auth-flow.ts (182)      # Auth flow state machine
│   └── auth-actions.ts (231)   # Auth UI action handlers
├── config/
│   └── project-config.ts (108) # .jackal walk-up loader (→ bridge)
├── jac/
│   ├── jac-bridge.ts (1012)    # Python toolchain bridge (sync + async)
│   ├── jac-cli.ts (253)        # Parse `jac check/format/test/run` output
│   ├── jac-doctor.ts (200)     # Doctor checks
│   ├── jac-workflows.ts (177)  # /osp, explain, diagram-to-model
│   ├── jac-types.ts            # JacDiagnostic type
│   ├── lsp-service.ts (364)    # LSP service lifecycle
│   ├── lsp-client.ts (384)     # LSP client transport
│   └── lsp-tools.ts (418)      # LSP tool function wrappers
├── orchestration/
│   ├── subagents.ts (282)      # Subagent catalog loading
│   ├── subagent-runner.ts (371) # Subagent execution
│   ├── chains.ts (175)         # .chain.md workflow catalog
│   └── frontmatter.ts (97)     # YAML frontmatter parser
├── project/
│   ├── skills.ts (517)         # SKILL.md discovery + loading
│   ├── project-init.ts (394)   # Project analysis for /init
│   ├── file-explorer.ts (94)   # File listing (→ bridge)
│   ├── gitignore.ts (41)       # Dead code (bridge handles this)
│   └── project-config.ts       # (moved to config/)
├── workflow/
│   ├── checkpoints.ts (369→343) # Checkpoint CRUD (→ bridge)
│   ├── tasks.ts (162→365)       # Task CRUD (→ bridge)
│   ├── custom-commands.ts (203→235) # Slash commands (→ bridge)
│   ├── context-input.ts (129)   # @file + !command expansion
│   ├── context-usage.ts (79)    # Token estimation
│   ├── file-mention-parser.ts (131) # @path:10-20 parsing
│   └── skill-commands.ts (30)   # /skills catalog
├── ui/
│   ├── completions.ts (183)     # Slash + @file autocomplete
│   ├── approval-display.ts (232) # Approval UI data
│   └── overlay-rows.ts (26)     # Task overlay formatting
└── render/
    └── mermaid-render.ts (505)   # Mermaid → ASCII
```

---

## Dependencies

**Runtime (`dependencies`):**
- `@earendil-works/pi-agent-core` — Agent loop, streaming, tool interface (dev dep, bundled)
- `@earendil-works/pi-ai` — Model providers, auth, streaming (dev dep, bundled)
- `pi-subagents` — Subagent orchestration patterns
- `pi-lsp-extension` — LSP client transport
- `pi-mcp-adapter` — MCP client adapter
- `pi-mermaid` — Mermaid rendering
- `@pi-unipi/notify` — Desktop notifications (patched to say "Jackal")
- `ignore` — `.gitignore` pattern matching
- `ink`, `react`, `@inkjs/ui` — TUI framework
- `wrap-ansi` — Terminal text wrapping

**Build/CI (`devDependencies`):**
- `typescript` — Compiles `src/` → `dist/`
- `vitest` — Test runner
- `patch-package` — Applies `patches/*`

---

## The bridge pattern (`src/jac/jac-bridge.ts` ↔ `lib/jac/bridge/toolchain_stdio.py`)

Jackal uses a **JSON-over-stdio bridge** to call Python toolchain modules from TypeScript:

```
src/jac/jac-bridge.ts          lib/jac/bridge/toolchain_stdio.py
    ┌──────────────┐                    ┌──────────────┐
    │ invokeBridge  │── spawn python3 ─→│  main()       │
    │ invokeBridge  │── stdin JSON ────→│  _dispatch()  │
    │ Sync          │←─ stdout JSON ────│  {"ok":true}  │
    └──────────────┘                    └──────────────┘
```

- **Sync** (`invokeBridgeSync`): `spawnSync` — blocks the Node event loop. ~20-50ms per call. Use for I/O operations where the call count is bounded (config loading, task CRUD, checkpoints).
- **Async** (`invokeBridge`): `spawn` — non-blocking. Use for long-running operations (jac check, format, test, run).

### What's in the bridge

80 ops total. Each op maps to a Python toolchain function:

| Op prefix | Count | Module |
|-----------|-------|--------|
| `find_binary`, `parse_check`, `fingerprint`, `format_diagnostics`, `run_*` | 10 | `lib/jac/jac/_cli_toolchain.py` |
| `doctor` | 1 | `lib/jac/jac/_doctor_toolchain.py` |
| `resolve_lsp_config` | 1 | `lib/jac/jac/_lsp_toolchain.py` |
| `project_list_files`, `project_estimate_selection` | 2 | `lib/jac/project/_file_explorer_toolchain.py` |
| `project_load_config`, `project_find_config_path`, `project_resolve_default_mode` | 3 | `lib/jac/config/_project_config_toolchain.py` |
| `frontmatter_*` | 4 | `lib/jac/orchestration/_frontmatter_toolchain.py` |
| `parse_file_mentions`, `parse_line_range`, `is_valid_file_path`, etc. | 5 | `lib/jac/workflow/_file_mention_parser_toolchain.py` |
| `estimate_tokens`, `compute_context_usage`, etc. | 5 | `lib/jac/workflow/_context_usage_toolchain.py` |
| `tasks_*` | 12 | `lib/jac/workflow/_tasks_toolchain.py` |
| `custom_commands_*` | 7 | `lib/jac/workflow/_custom_commands_toolchain.py` |
| `dev_mode_*` | 9 | `lib/jac/agent/_dev_mode_toolchain.py` |
| `overlay_*` | 3 | `lib/jac/ui/_overlay_rows_toolchain.py` |
| `checkpoint_*` | 12 | `lib/jac/workflow/_checkpoints_toolchain.py` |
| `workflows_*` | 9 | `lib/jac/jac/_workflows_toolchain.py` |

### Bridge response format

Every bridge response is `{"ok": true, ...payload}` or `{"ok": false, "error": "...", "trace": "..."}`.

The payload key depends on what the op returns:
- `{"result": <value>}` — most ops
- `{"diagnostics": [...]}` — `parse_check`
- `{"fingerprint": "..."}` — `fingerprint`
- `{"formatted": "..."}` — `format_diagnostics`
- `{"binary": "..."}` — `find_binary`

### When to use the bridge vs local TS

**Delegate to bridge when:**
- The operation does file I/O (read/write `.jackal`, `tasks.json`, checkpoints)
- The call frequency is bounded (1-5 calls per user action)
- Python is or should be the source of truth (e.g. `.jackal` config walking)

**Keep local TS when:**
- The function is called in tight loops (e.g. `parseFrontmatter` called dozens of times during skill loading)
- The function has deep TS type dependencies (`pi-agent-core`, `typebox`, etc.)
- The function is purely computational and latency-sensitive (token estimation, regex matching)

---

## `lib/jac/` — Jac toolchain (Python source of truth)

This directory is the Jac-native codebase. It follows a consistent pattern for each module:

```
lib/jac/<domain>/
├── _<name>_toolchain.py   # Python implementation (source of truth)
└── <name>.jac             # Jac wrapper module (imports Python via ::py:: block)
```

The `.jac` wrapper follows a boilerplate pattern:
```jac
"""Docstring."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "<domain>")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _<name>_toolchain import (func1, func2, ...)
::py::
```

### `lib/jac/` directory structure

```
lib/jac/
├── main.jac                  # Entry point for --check (toolchain + npm agent loop)
├── bridge/
│   └── toolchain_stdio.py    # JSON stdio bridge dispatcher (80 ops)
├── jac/                      # Jac CLI toolchain (Phase 1)
│   ├── _cli_toolchain.py     # jac check, format, test, run, fingerprint
│   ├── _doctor_toolchain.py  # jac doctor report
│   ├── _lsp_toolchain.py     # LSP config resolution
│   ├── _workflows_toolchain.py # /osp, explain, diagram-to-model prompts
│   ├── _npm_bridge.py        # npm agent loop spike
│   ├── cli.jac, doctor.jac, lsp_config.jac, types.jac, workflows.jac
├── config/                   # Phase 2A.1
│   ├── _project_config_toolchain.py # .jackal walk-up, JSON parse, mode resolution
│   └── project_config.jac
├── project/                  # Phase 2A.2-3
│   ├── _gitignore_toolchain.py      # Gitignore matching engine
│   ├── _file_explorer_toolchain.py  # Project file listing + token estimates
│   ├── gitignore.jac, file_explorer.jac
├── orchestration/            # Phase 2C
│   ├── _frontmatter_toolchain.py    # YAML frontmatter parser
│   └── frontmatter.jac
├── workflow/                 # Phase 2D
│   ├── _file_mention_parser_toolchain.py # @path:10-20 parsing
│   ├── _context_usage_toolchain.py       # Token estimation
│   ├── _tasks_toolchain.py               # Task CRUD + persistence
│   ├── _custom_commands_toolchain.py     # Slash command loading/expansion
│   ├── _checkpoints_toolchain.py         # Checkpoint CRUD + git file snapshots
│   └── *.jac wrappers
├── agent/                    # Phase 2E
│   ├── _dev_mode_toolchain.py           # Mode logic, destructive bash, approval policy
│   └── dev_mode.jac
├── ui/                       # Phase 2F
│   ├── _overlay_rows_toolchain.py       # Task overlay formatting
│   └── overlay_rows.jac
├── spike/                    # Phase 0 feasibility spike
│   ├── agent_spike.jac
│   └── npm_agent_spike.mjs
└── tests/                    # Python + Jac tests
    ├── test_project_config.py       # 12 pytest tests
    ├── test_phase2_leaf_modules.py  # 34 pytest tests
    ├── cli_test.jac                 # Jac tests for cli toolchain
    └── file_explorer_test.jac       # Jac tests for file explorer
```

---

## Environment variables

| Variable | Set by | Purpose |
|----------|--------|---------|
| `JACKAL_AGENT_DIST` | `jackal.sh` | Path to `dist/index.js` for facade dynamic import |
| `JACKAL_AGENT_CWD` | `jackal.sh` (default `$PWD`) | User project root: sessions, `.jackal`, tools, LSP |
| `JACKAL_AGENT_DIR` | `jackal.sh` → `$REPO/pi` | Package bundle: `SYSTEM.md`, skills, default subagents, auth path |
| `JACKAL_MODE` | `--mode` flag | `normal` \| `auto-accept` \| `yolo` \| `plan` \| `ask` |
| `JACKAL_HEAP_MB` | optional | Node heap (default 4096 in launcher) |
| `JACKAL_SKIP_TUI_COMPILE` | optional | `1` = use cached `.jac/tui` |
| `JACKAL_TUI_OUT` | optional | Override TUI output dir (default `.jac/tui`) |
| `JACKAL_CONTEXT_MAX` | optional | Context window override for `/usage` / auto-compact |
| `JACKAL_ROOT` | optional | Override Jackal repo root (for bridge resolution) |
| `JACKAL_TOOLCHAIN_PYTHON` | optional | Override Python binary (default `python3`) |
| `JAC_DISABLED_PLUGINS` | `jackal.sh` | Disables `jac-desktop` in CLI |

**Auth:** `jackal.sh` symlinks `pi/auth.json` → `~/.pi/agent/auth.json` if missing. Runtime resolves auth via `JACKAL_AGENT_DIR/auth.json` or `~/.jackal/auth.json`.

**Sessions:** `<JACKAL_AGENT_CWD>/.jackal/sessions/*.jsonl` (+ index). Legacy Pi sessions may exist under `pi/sessions/` in the Jackal repo (user data).

---

## `templates/` (Ink UI — Jac, not TypeScript)

| File | Role |
|------|------|
| `shell.cl.jac` | Main app: layout, slash routing, overlays (help, explorer, tasks, checkpoints, diff editor, auth) |
| `components/*.cl.jac` | transcript, statusbar, userinput, authflow, toolline, filediff, helppanel, … |
| `jackal_agent_facade.mjs` | React hooks bridging Ink ↔ `createNextAgent` (copied to `.jac/tui/jac_pi_runtime_shim.mjs`) |
| `markdown.mjs`, `text-wrapping.mjs` | Rendered assistant markdown in TUI |
| `diff_engine_node.mjs` | Node sidecar for interactive diff accept/reject |

**Compile flow:** `jac tui shell.cl.jac --out .jac/tui --no_run` then `jackal.sh` **postprocess_tui**: rename `usePi*` → `useJackal*`, copy facade/markdown/diff, run `scripts/fix-tui-module.mjs`, `patch-tui-runner.mjs`, `dedupe-jac-runtime.mjs`.

**UI imports hooks from** `./jac_pi_runtime_shim.mjs` (resolved at runtime in `.jac/tui/`).

---

## `pi/` — config bundle (not runtime code)

Legacy name "pi"; this directory is **data**, not the Pi extension.

| Path | Used for |
|------|----------|
| `pi/SYSTEM.md` | Default system prompt (also try `<cwd>/jackal/SYSTEM.md`) |
| `pi/mcp.json` | MCP server config — read from **`<JACKAL_AGENT_CWD>/pi/mcp.json`** if present |
| `pi/skills/*/SKILL.md` | On-demand skills (26); indexed into system prompt |
| `pi/prompts/*.md` | Workflow templates (osp, explain-*, convert-python, review-idioms, diagram-to-model) |
| `pi/.pi/agents/*.md` | Built-in subagents: scout, architect, implementer |
| `pi/chains/*.chain.md` | scout-and-design, pipeline |
| `pi/settings.json` | Default models / subagent overrides (reference; runtime uses auth + `.jackal`) |
| `pi/auth.json` | Symlink to global provider credentials |
| `patches/` | `patch-package` — e.g. notify branded "Jackal" |

Project overrides: `<cwd>/.jackal/`, `<cwd>/subagents/`, `<cwd>/chains/`, `<cwd>/.jackal/commands/*.md`.

---

## Agent loop behavior (mental model)

1. **Boot:** `createNextAgent` → `JackalAgentSession.initialize()` → `bridgeEvents` → store `phase: ready`.
2. **Background:** `scheduleMcpConnect()` (lazy, after first frame), `scheduleLspConnect()` (unless `.jackal` `lsp: false`).
3. **Send:** User text → optional slash/custom-command expansion → `Agent.prompt()` → streaming events → bridge updates `streamingText` + transcript.
4. **Tools:** `tool_execution_start/end` → transcript tool rows + `toolExecutions` map; approval queue in normal mode.
5. **Queue:** If busy, messages go to `OutboundMessageQueue`; drained on `agent_end` (`queue_changed` events).
6. **Modes:** `dev-mode.ts` blocks write/edit/format/MCP mutators in `plan` and `ask`.
7. **Dispose:** `actions.dispose()` on exit; session auto-save.

**Store phases:** `booting` → `ready` | `streaming` | `compacting` | `retrying` | `error`.

**`createNextAgent()` returns:** `{ store, uiContext, authFlow, authActions, actions: { send, abort, resolveDialog, setModel, ... }, dispose }`. The `actions` bag is the public API surface consumed by the Ink shell via the facade.

---

## Dev modes

| Mode | Behavior |
|------|----------|
| `normal` | Tool approval for destructive ops |
| `auto-accept` | Auto-approve tools |
| `yolo` | Auto-approve including risky bash |
| `plan` | Read-only: blocks write/edit/format/create/task mutations |
| `ask` | Same blocks as plan; Q&A oriented system appendix |

Cycle in UI: **Shift+Tab**. CLI: `./jackal.sh --mode plan`. Config: `.jackal` `mode` or legacy `plan: true`.

Blocked tool set: `READ_ONLY_MODE_BLOCKED_TOOLS` in `src/agent/dev-mode.ts` (mirrored in `lib/jac/agent/_dev_mode_toolchain.py`):
`write`, `edit`, `jac_format`, `jac_fix`, `jac_create`, `create_task`, `update_task`, `delete_task`, `format_jac`, `execute_command`.

---

## Tools exposed to the LLM (runtime names)

Registered in `createCoreTools()` (`src/agent/tools.ts`) + MCP dynamic tools + `agent` subagent tool.

**Tier 1 — core loop:** `read`, `write`, `edit`, `bash`, `glob`, `jac_check`, `jac_format`, `jac_fix`, `jac_test`, `jac_run`, `jac_cli`, `jac_doctor`, `jac_create`, `jac_list_templates`

**Tier 2 — LSP:** `diagnostics`, `hover`, `definition`, `references` (via `lsp-tools.ts`)

**Tier 3 — tasks / viz:** `create_task`, `update_task`, `list_tasks`, `delete_task`, `mermaid`, `compact_context`, `web_search`, `web_fetch` (if configured)

**Tier 4 — MCP:** All tools from `jac mcp` (validate_jac, check_syntax, run_jac, search_docs, get_resource, format_jac, …) — see `pi/mcp.json` `directTools` for eager subset

**Tier 5 — orchestration:** `agent` (subagent delegate; uses `pi-subagents` patterns)

**Post-write hooks:** After `write`/`edit` on `.jac` when enabled in `.jackal`: `autoformat` runs `jac format` first, then `autocheck` runs `jac check`.

---

## Slash commands (implemented in `shell.cl.jac`)

Handled locally in the shell (not Pi SDK). Send via `submit_main("/command")`.

| Command | Action |
|---------|--------|
| `/help` | Toggle help panel |
| `/login`, `/logout`, `/model`, `/cancel` | Auth flows |
| `/abort` | Cancel active run |
| `/clear`, `/new` | New session (clears agent memory) |
| `/compact` | Context compaction (`--preview`, `--restore`, `--llm`, `--mechanical`) |
| `/usage`, `/context-max` | Context utilization |
| `/resume`, `/rename`, `/export` | Session management |
| `/explorer` | Multi-select `@file` injection |
| `/checkpoint`, `/tasks` | Overlays |
| `/init` | Generate AGENTS.md for project |
| `/jac explain …`, `/jac diagram-to-model` | Prompt workflows |
| `/jac-check`, `/jac-test`, `/jac-format`, `/jac-doctor`, `/jac …` | Tool-backed |
| `/fix` | Check/fix loop |
| `/plan`, `/osp` | Plan prompt / OSP workflow |
| `/create` | `jac create` templates |
| `/agents`, `/commands`, `/skills` | Catalogs |
| `/diff` | Interactive diff engine overlay |
| `/mcp` | MCP status |
| `/exit` | Quit |

Custom: `<cwd>/.jackal/commands/*.md`. Skills: `/skill:name` expansion in `skills.ts`.

Full list also in `docs/QUICK_REFERENCE.md`.

---

## `.jackal` project config

Walks up from `JACKAL_AGENT_CWD`. Keys (see `src/config/project-config.ts`):

`autocheck`, `autoformat`, `verbose`, `mode`, `plan` (legacy), `maxFixAttempts`, `mermaid`, `notify`, `lsp`, `subagents`, `contextMax`, `sessions` (autoSave, maxCount, retentionDays), `alwaysAllow`, `permissionPatterns`, `autoCompact`, `compactStrategy`.

The walk-up + JSON parsing is delegated to `lib/jac/config/_project_config_toolchain.py` via the bridge.

---

## Tests

| Suite | Location | Run |
|-------|----------|-----|
| Adapter/runtime | `tests/adapter/*.test.ts` (24 files) | `npm run test:adapter` |
| Session | `tests/session/*.test.ts` (1 file) | part of `npm test` |
| TUI components | `tests/tui/*.test.mjs` (13 files) | `npm run test:tui` (needs fixtures: `npm run test:tui:compile`) |
| Python toolchain | `lib/jac/tests/test_*.py` (2 files, 46 tests) | `python3 -m pytest lib/jac/tests/` |
| Jac | `lib/jac/tests/*_test.jac` (2 files, 8 tests) | `jac test lib/jac/tests/` |

**Total:** 279 TS tests + 46 Python tests + 8 Jac tests.

Hot paths with coverage: `bridgeEvents`, store, dev-mode, permissions, smoke boot, outbound queue, jac-cli parsing, file-mention-parser, context-input, auto-compact-config, tool-output-limit, mcp-schema, overlay-rows, skills, session-permissions.

**Test runner:** Vitest for TS. Default timeout 5000ms — long-running tests (like `skills.test.ts` which does file I/O) may need explicit timeout bumps.

---

## Human handoff (jac-ink / jaclang)

**Agents do not implement these.** Document and tell the human.

| Symptom / need | Owner | Notes |
|----------------|-------|-------|
| `jac tui` missing | jac-ink install | `./scripts/setup-jac-ink.sh` |
| `@jac/pi` bundling, `.cl.jac` stem, Vite bypass | jac-ink / jaclang / jac-client | See `docs/JAC-TUI.md` |
| Formal `--adapter` flag instead of env + copy facade | jac-ink | |
| Hook names (`useJackalBoot` vs `usePiBoot`) | jac-ink emit | `jackal.sh` sed workaround is temporary |
| Compiler strips `@jac/pi` import | jac-ink `_ensure_pi_import()` | |

**Workarounds in this repo (until upstream fixes):** `jackal.sh` `postprocess_tui`, `scripts/fix-tui-module.mjs`, copying `jackal_agent_facade.mjs` → `jac_pi_runtime_shim.mjs`.

---

## What was removed / do not restore

- `pi/extensions/jackal/*` — deleted; logic lives in `src/`
- `./jackal.sh --pi` / `JACKAL_CLASSIC_PI` — hard error
- Pi extension as launch path — see `docs/CONSOLIDATION_PLAN.md`

---

## Docs index (deeper dives)

| Doc | Contents |
|-----|----------|
| `docs/FEATURES.md` | Feature checklist + status |
| `docs/JAC-TUI.md` | jac-ink vs jackal repo boundary |
| `docs/CONSOLIDATION_PLAN.md` | Runtime consolidation phases |
| `docs/MIGRATION-EXECUTION-PLAN.md` | Jac migration execution plan (phases 0-5) |
| `docs/PLAN.md` | Implementation phases |
| `docs/QUICK_REFERENCE.md` | Slash commands, flags, config |
| `docs/PLAN_MODE.md` | Plan mode UX |
| `docs/NANOCODER-PARITY.md` | TUI parity gaps |
| `ROADMAP.md` | Product direction |
| `lib/jac/README.md` | lib/jac structure and conventions |
| `reference/pi-lsp-extension/` | Legacy reference only |

---

## Allowed tools (Jackal the product — for comparison)

When **using** Jackal as an agent on Jac projects, prefer the tier list in the original product spec: Jac MCP validate/run/check, read/write/edit/bash, LSP, subagents. Full table remains in `docs/QUICK_REFERENCE.md` § Allowed Tools.

For **developing Jackal itself**, use repo tools (read, grep, bash, edit `src/` + `templates/`), run `npm run build:agent` + tests, and hand off jac-ink issues to the human.

---

## Current priorities (from maintainers)

1. Fast TUI boot — MCP/LSP deferred after first frame
2. Stable streaming / transcript / tool rows in Ink
3. Harden adapter + bridge + outbound queue
4. Jac MCP as primary validate/run surface
5. Port remaining polish per `docs/NANOCODER-PARITY.md`

---

## Subagents (built-in)

| Agent | Model tier | Role |
|-------|------------|------|
| `scout` | Fast (Haiku-class) | Codebase recon |
| `architect` | Reasoning (Sonnet-class) | OSP / design |
| `implementer` | Capable (Sonnet-class) | Edits |

Chains: `pi/chains/pipeline.chain.md` (scout→planner→worker), `scout-and-design.chain.md`.

Invoke via `agent` tool or orchestration APIs in `subagent-runner.ts`.

---

## Practical gotchas (lessons from working in this repo)

### Bridge performance

- **Sync bridge calls are ~20-50ms** each (spawn Python subprocess). Fine for I/O (config loading, task CRUD), **too expensive for tight loops**.
- Skills loading calls `parseFrontmatter` dozens of times. Delegating that to the bridge caused test timeouts. Keep hot-path pure logic in TS.
- Batch ops exist (`frontmatter_parse_batch`) for when cross-language batch processing is needed.

### TS ↔ Python type boundary

- The bridge is untyped JSON. Python returns `dict`/`list`/`str`/`None`; TS casts them to typed interfaces.
- `null` in Python ↔ `null` in JSON, but TS often uses `undefined`. Bridge functions need explicit `?? undefined` / `?? null` normalization.
- Python `dict` keys are strings; TS `Record<string, unknown>` matches cleanly.

### Build and test

- `npm run build:agent` (tsc) is fast (<5s). Always run after editing `src/`.
- `npm test` (vitest) takes ~14s. The `cli-harness.test.ts` smoke test has a known timeout issue (waits for `agent_end` event which can be flaky). Exclude it with `--exclude`.
- `npm run check:jac` runs `lib/jac/main.jac --check` + `jac test` harness. This verifies Python toolchain modules compile and Jac tests pass.
- Python tests: `python3 -m pytest lib/jac/tests/`. Fast (<1s).
- After editing `.py` toolchain files, test the bridge directly: `echo '{"op":"<op>","cwd":"..."}' | python3 lib/jac/bridge/toolchain_stdio.py`

### Jac conventions

- Jac wrapper files (`.jac`) are boilerplate: docstring + `::py::` block that adds the toolchain dir to `sys.path` and imports functions.
- In Jac tests, `root` is a built-in reference name; use `tmp_dir` or similar instead.
- `_pycache__` directories accumulate in `lib/jac/`. Gitignore handles them; don't commit `.pyc` files.

### Module dependency chains

- `agent-session.ts` (1000 LOC) imports from almost every other module. Changes to leaf modules propagate upward through it.
- `config/project-config.ts` is a dependency of: `dev-mode.ts`, `agent-session.ts`, `adapter.ts`, `tools.ts`, `session.ts`, `subagents.ts`. The bridge delegation means all these modules now indirectly depend on the Python toolchain being available.
- `orchestration/frontmatter.ts` is imported by `custom-commands.ts`, `skills.ts`, `subagents.ts`. It's a hot path — keep local.
- `src/project/gitignore.ts` is dead code (the bridge handles gitignore matching internally). Safe to ignore.

### Common workflows

**Adding a new bridge op:**
1. Write the Python function in the appropriate `_*_toolchain.py`
2. Add an `if op == "your_op"` block in `toolchain_stdio.py` `_dispatch()`
3. Add a bridge function in `src/jac/jac-bridge.ts` (sync or async)
4. Update the TS module to call the bridge function
5. Add Python tests in `lib/jac/tests/`
6. Run `npm run build:agent && npm test -- --exclude tests/adapter/cli-harness.test.ts`
7. Run `python3 -m pytest lib/jac/tests/`

**Adding a new toolchain module:**
1. Create `lib/jac/<domain>/_<name>_toolchain.py`
2. Create `lib/jac/<domain>/<name>.jac` (boilerplate wrapper)
3. Add import in `toolchain_stdio.py`
4. Add ops + dispatch entries
5. Add bridge functions in `jac-bridge.ts`
6. Add `<domain>` to `lib/jac/main.jac` check scope
7. Write Python tests

---

## Phase 2 migration status

### Ported modules (15 Python toolchain modules)

| Directory | Modules |
|-----------|----------|
| `lib/jac/jac/` | cli, doctor, lsp_config, workflows, types |
| `lib/jac/config/` | project_config |
| `lib/jac/project/` | gitignore, file_explorer |
| `lib/jac/orchestration/` | frontmatter |
| `lib/jac/workflow/` | file_mention_parser, context_usage, tasks, custom_commands, checkpoints |
| `lib/jac/agent/` | dev_mode |
| `lib/jac/ui/` | overlay_rows |

### Bridge delegation (TS → Python)

- `config/project-config.ts` → bridge for `.jackal` walk-up + mode resolution
- `project/file-explorer.ts` → bridge for file listing
- `workflow/tasks.ts` → bridge for task CRUD
- `workflow/custom-commands.ts` → bridge for command loading
- `workflow/checkpoints.ts` → bridge for checkpoint CRUD

### TS keeps local copy (Python = source of truth, TS mirrors for perf)

- `orchestration/frontmatter.ts`, `workflow/file-mention-parser.ts`, `workflow/context-usage.ts`, `agent/dev-mode.ts`, `ui/overlay-rows.ts`

### Not yet ported (requires deeper changes)

Modules with deep TS runtime dependencies (typebox, `pi-agent-core` types, `child_process`):
- `agent/mcp-schema.ts`, `agent/session-permissions.ts`, `agent/task-tools.ts`, `agent/web-tools.ts`
- `render/mermaid-render.ts`, `ui/approval-display.ts`, `ui/completions.ts`
- `workflow/context-input.ts`, `agent/tool-output-limit.ts`
- `project/skills.ts`, `project/project-init.ts`, `agent/system-prompt.ts`, `workflow/skill-commands.ts`

### Numbers

- 80 bridge ops in `toolchain_stdio.py`
- 67 bridge functions in `jac-bridge.ts`
- 46 Python tests (12 config + 34 leaf modules)
- 279 TS tests — all passing
- ~2000 LOC of Python toolchain code

---

## Patches

`patches/@unipi+notify+2.0.1.patch` — desktop notifications say "Jackal". Applied on `npm install` via `postinstall`.

---

*Last updated 2026-05-25 — comprehensive agent onboarding including Phase 2 migration, bridge architecture, dependency chains, and practical gotchas.*
