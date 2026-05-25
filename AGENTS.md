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
npm run check            # or ./jackal.sh --check
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
| `JAC_DISABLED_PLUGINS` | `jackal.sh` | Disables `jac-desktop` in CLI |

**Auth:** `jackal.sh` symlinks `pi/auth.json` → `~/.pi/agent/auth.json` if missing. Runtime resolves auth via `JACKAL_AGENT_DIR/auth.json` or `~/.jackal/auth.json`.

**Sessions:** `<JACKAL_AGENT_CWD>/.jackal/sessions/*.jsonl` (+ index). Legacy Pi sessions may exist under `pi/sessions/` in the Jackal repo (user data).

---

## `src/` module map (where to edit what)

| Path | Responsibility |
|------|----------------|
| `core/adapter.ts` | **`createNextAgent()`** — wires store, session, bridge, auth, exposes `actions.*` for shell/facade |
| `core/store.ts` | Immutable `AgentSnapshot`: phase, transcript, tools, MCP, queue, approvals |
| `core/bridge.ts` | Session events → store mutations (`agent_start`, `tool_execution_*`, `mcp_ready`, `queue_changed`, …) |
| `core/ui-context.ts` | Dialogs, notifications for Ink overlays |
| `core/agent-busy.ts` | Busy detection for queue / abort UX |
| `core/tool-summary.ts` | One-line tool labels in transcript |
| `session/agent-session.ts` | Agent loop, tools, MCP lazy connect, LSP, autocheck, slash expansion, compaction |
| `session/session.ts` | Disk persistence, 30s auto-save |
| `session/session-index.ts` | Session list, resume, retention prune |
| `session/outbound-queue.ts` | Queue user messages while agent busy |
| `session/auto-compact.ts` / `llm-compact.ts` | Threshold compaction (LLM default, mechanical fallback) |
| `agent/tools.ts` | Core tools: read, write, edit, bash, glob, jac_*, LSP, mermaid, … |
| `agent/dev-mode.ts` | Modes + read-only tool blocks (plan/ask) |
| `agent/tool-approval.ts` | Pending destructive tool approval |
| `agent/mcp-client.ts` | Stdio MCP to `jac mcp` (reads `<cwd>/pi/mcp.json`) |
| `agent/system-prompt.ts` | Loads `jackal/SYSTEM.md` or `pi/SYSTEM.md` + skill index |
| `auth/*` | pi-ai OAuth/API keys, model picker state |
| `config/project-config.ts` | Walk-up `.jackal` JSON loader |
| `jac/jac-cli.ts` | Parse `jac check`, format, test, run |
| `jac/lsp-*.ts` | Jac LSP client + tool wrappers |
| `jac/jac-workflows.ts` | `/osp`, explain prompts, `/init`, diagram-to-model |
| `orchestration/subagents.ts` | Load `pi/.pi/agents/*.md` + project `subagents/` |
| `orchestration/chains.ts` | `.chain.md` workflows |
| `workflow/*` | Checkpoints, tasks, custom commands, file mentions, context usage |
| `project/skills.ts` | SKILL.md discovery (package + project) |
| `cli/run.ts` | Headless `jackal run` |
| `ui/completions.ts` | Slash + `@file` completions for facade |
| `render/mermaid-render.ts` | Mermaid → ASCII |

**Public API:** everything re-exported from `src/index.ts` (also `dist/index.js`).

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

Legacy name “pi”; this directory is **data**, not the Pi extension.

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
| `patches/` | `patch-package` — e.g. notify branded “Jackal” |

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

Blocked tool set: `READ_ONLY_MODE_BLOCKED_TOOLS` in `src/agent/dev-mode.ts`.

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

---

## Tests

| Suite | Location | Run |
|-------|----------|-----|
| Adapter/runtime | `tests/adapter/*.test.ts` | `npm run test:adapter` |
| Session | `tests/session/*.test.ts` | part of `npm test` |
| TUI components | `tests/tui/*.test.mjs` | `npm run test:tui` (needs fixtures: `npm run test:tui:compile`) |

Hot paths with coverage: `bridgeEvents`, store, dev-mode, permissions, smoke boot, outbound queue, jac-cli parsing.

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
| `docs/PLAN.md` | Implementation phases |
| `docs/QUICK_REFERENCE.md` | Slash commands, flags, config |
| `docs/PLAN_MODE.md` | Plan mode UX |
| `docs/NANOCODER-PARITY.md` | TUI parity gaps |
| `ROADMAP.md` | Product direction |
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

## Patches

`patches/@unipi+notify+2.0.1.patch` — desktop notifications say “Jackal”. Applied on `npm install` via `postinstall`.

---

*Last expanded for agent onboarding — covers runtime split, file ownership, env vars, and edit boundaries so mapping the repo each session is unnecessary.*
