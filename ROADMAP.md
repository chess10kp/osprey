# Jackal Roadmap

**A Jac-native, terminal-first coding agent** that gives Jac developers the agentic workflow Jac Coder has, but outside VS Code — with keyboard ergonomics, multimodal context, CLI/toolchain awareness, and Jac-specific project intelligence.

**Reference baseline:** [`reference/nanocoder/`](reference/nanocoder/) is the primary reference for what a complete terminal coding agent looks like (Ink TUI, tool approval modes, session lifecycle, context compression, subagents, MCP, non-interactive `run` mode, etc.). Jackal must reach nanocoder parity on agent *foundation* first, then layer Jac differentiation on top.

**Live status:** P0–P8 are **implemented** in `src/` + `templates/shell.cl.jac` (see [`docs/FEATURES.md`](docs/FEATURES.md)). P9 (LSP depth, RAG, migration agent) remains deferred research.

**Nanocoder parity:** Track A foundation is complete. Remaining gaps (text wrapping, rich approval UI, custom tools, scheduler, `/tune`) are documented in [`docs/NANOCODER-PARITY.md`](docs/NANOCODER-PARITY.md).

> **Note:** Detailed Track A sections below (A1–A13) retain historical step lists. For current gap analysis, prefer **NANOCODER-PARITY.md** over stale "Missing" cells in those tables.

---
## Current snapshot (2026-05-24)

| Area | Status | Notes |
|------|--------|-------|
| Headless runtime (`src/`) | Done | Store, bridge, auth, session, tools, MCP, subagents |
| Ink shell (`templates/shell.cl.jac`) | Done | Transcript, streaming, auth, slash routing, explorer, approval |
| Core agent tools | Done | read, write, edit, bash, glob + path cwd guards |
| Jac MCP | Done | Lazy boot via `scheduleMcpConnect`; `/mcp` status |
| Jackal slash workflows | Done | `/fix`, plan mode, subagents, Jac toolchain commands |
| Terminal agent foundation | Done | Modes, `@file`/`!cmd`, checkpointing, `/resume`, `jackal run`, explorer |
| Jac differentiators | Done | OSP, Python→Jac, idiom review, explain, diagram-to-model (text) |
| Advanced (P9) | Deferred | Deep LSP port, RAG, graph trace visualizer, migration agent |
| Nanocoder gaps | Documented | See `docs/NANOCODER-PARITY.md` — polish + optional features |

---

## Roadmap tracks

Two parallel tracks. **Track A** is required for any credible terminal coding agent. **Track B** is what makes Jackal worth using over a generic agent.

| Track | Goal | Nanocoder analog |
|-------|------|------------------|
| **A — Terminal Agent Foundation** | Reliable TUI agent: chat, tools, sessions, safety, extensibility | Core nanocoder feature set |
| **B — Jac Differentiators** | Jac toolchain loops, OSP reasoning, Jac knowledge pack | N/A (Jackal-specific) |

Phases below are numbered **P0–P8**. Lower numbers are prerequisites. Items in the same phase can often ship in parallel.

---

# Track A — Terminal Agent Foundation

Everything in this section is table-stakes for a daily-usable terminal coding agent. Nanocoder docs under `reference/nanocoder/docs/features/` are the detailed spec.

## A1. Runtime & boot — **Phase P0**

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| Headless adapter | `createNextAgent()` wires store, bridge, auth, session | Done in `src/adapter.ts` | Done |
| Agent loop | `pi-agent-core` prompt/stream/abort | Wire `JackalAgentSession`; verify with real credentials | Done |
| Immutable store | Single source of truth for Ink via `AgentStore` + bridge events | Extend snapshot for new subsystems (modes, tasks, MCP state) | Done |
| Auth + models | OAuth, API keys, model picker via `pi-ai` | `/login`, `/logout`, `/model` in shell | Done |
| Project CWD | Respect `JACKAL_AGENT_CWD` for tools and sessions | Document + enforce in all tool paths | Done |
| System prompt | Load `jackal/SYSTEM.md` at session boot | Hook in `src/runtime/system-prompt.ts` | Done |
| Graceful dispose | `/exit`, Ctrl+C without corrupting session | SIGINT messaging polish | Partial |
| Smoke / CI path | Non-interactive boot verification | `npm run check`, `jackal run --check` | Done |
| Fast TUI boot | Render shell before MCP/subsystems finish | Lazy MCP spawn after first frame | Missing |

**Exit criteria:** `./jackal.sh` boots, authenticates, runs 3+ prompt cycles, disposes cleanly.

---

## A2. Ink shell & input — **Phase P1**

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| Boot / error screen | Show adapter boot state and failures | Ink component from nanocoder patterns | Done |
| Welcome + status bar | Phase, model, provider, session name | Extend bar with mode, context %, MCP status | Done |
| Message transcript | User + assistant scrollback | Pagination for long sessions | Done |
| Streaming display | Live token stream | Verify on real provider | Done |
| Multiline input | `/multiline`, Ctrl+D to send | Document Ctrl+J newline (nanocoder convention) | Done |
| Slash routing | `/help`, `/clear`, `/abort`, `/exit`, auth commands | Central command registry in adapter + shell | Done |
| Slash completions | Tab-complete commands | Extend to flags and subcommands | Done |
| Auth overlays | Provider picker, OAuth, API key, model picker | Error retry paths | Done |
| Dialog overlays | Select / confirm / input from extension UI context | Used by wizards later | Done |
| Tool timeline UI | Running/done tool rows in transcript | Expandable input/result (Ctrl+O compact toggle) | Partial |
| Notifications | Desktop + in-TUI notify on attention | Wire `notify()` from adapter | Done |
| Help panel | `/help` command reference | Keep in sync with registered commands | Done |

**Steps to finish P1:**

1. Tool detail rows — name, truncated args, duration, expandable result (`reference/nanocoder/source/utils/tool-result-display.tsx`).
2. Ctrl+O compact tool output toggle in `shell.cl.jac`.
3. Esc cancels in-flight response; double-Esc clears input (nanocoder keyboard model).
4. SIGINT vs abort vs exit messaging.

**Exit criteria:** User can follow a multi-tool turn without debug logs.

---

## A3. Core agent tools — **Phase P1**

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| Read / write / edit | File access for the agent | Path validation, gitignore respect | Done |
| Bash tool | Run shell commands | Visible execution; cwd safety defaults | Done |
| Tool event bridge | Map tool start/end → store | Already in bridge; verify all tools emit | Done |
| Working directory safety | Sensible defaults for destructive ops | Block or warn outside project root | Missing |
| MCP client | Spawn `jac mcp`; expose Jac toolchain tools | Lazy load; `/mcp` status command | Partial |

**Steps to finish P3:**

1. Lazy MCP connect after TUI render; status bar reflects connecting / ready / error.
2. `/mcp` — list connected servers and tool count.
3. Path validators for read/write/bash (nanocoder: `path-validators.ts`, `path-validation.ts`).
4. Optional: gitignore-aware file search for `@` mentions.

**Exit criteria:** Agent reads a file, edits it, runs `jac check` via bash or MCP; tool rows appear live.

---

## A4. Context input syntax — **Phase P2**

Nanocoder special input (see `reference/nanocoder/docs/features/commands.md`).

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| `@file` mentions | Fuzzy file autocomplete; Tab to accept | `completions.ts` + cursor-aware mention | Done |
| `@file:10-20` | Line-range inclusion | `file-mention-parser.ts` + `context-input.ts` | Done |
| `!command` | Inline bash; output becomes context | `context-input.ts` | Done |
| `/explorer` | Interactive file tree for multi-select context | Shell overlay + `file-explorer.ts` | Done |
| Token estimation | Warn on large `@` selections (10k+ tokens) | Explorer hint + expand warning | Done |

**Steps:**

1. `@` autocomplete in `src/completions.ts` + shell input handler (respect `.gitignore`).
2. Line-range parsing in file content loader.
3. `!` prefix: run command, append stdout/stderr as user context block.
4. `/explorer` Ink overlay: tree nav, Space multi-select, Esc injects `@` mentions.
5. Token estimate footer on explorer selection.

**Maps to roadmap phase:** P2 (foundation). Required before multimodal and long-session workflows feel usable.

---

## A5. Development modes & tool approval — **Phase P2**

Nanocoder: `reference/nanocoder/docs/features/development-modes.md`.

| Mode | Behaviour | Jackal target |
|------|-----------|---------------|
| **Normal** | Confirm each tool | Default for unfamiliar repos |
| **Auto-accept** | Most tools auto-run; bash/destructive git still prompt | Daily driver |
| **Yolo** | All tools auto-run | Power users |
| **Plan** | Read-only tools only; structured plan output | Already specced in extension; port to Ink runtime |

| Feature | Steps | Status |
|---------|-------|--------|
| Mode state in store | `mode: normal \| auto-accept \| yolo \| plan` | Missing |
| Shift+Tab toggle | Cycle modes; status bar indicator (red in yolo) | Missing |
| `--mode` CLI flag | Boot into mode; validate values | Missing |
| Tool approval queue | `tool-approval-queue.ts` pattern — approve/reject UI | Missing |
| Destructive op detection | Gate bash + git hard reset / force delete in auto-accept | Missing |
| Plan mode tool filter | Strip write/bash/git-write; keep read + Jac MCP read-only tools | Missing |
| Plan → execute handoff | Preserve transcript; `[DONE:n]` step markers | Missing |

**Steps:**

1. Add `mode` to store + `.jackal` config key `plan` / default mode.
2. Ink approval dialog for pending tool calls (reuse `ui-context` confirm).
3. Filter tool registry per mode in `src/runtime/tools.ts`.
4. Port plan-mode constants and step tracking from legacy extension (`plan-mode.ts` patterns).
5. Shift+Tab handler in `shell.cl.jac`.

**Maps to roadmap phase:** P2. Prerequisite for safe autonomous `/fix` loops.

---

## A6. Session lifecycle — **Phase P3**

Nanocoder: `reference/nanocoder/docs/features/session-management.md`.

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| Auto-save | Periodic disk flush | Config: interval, max messages | Partial |
| Restore on boot | Reload transcript + model | `.jackal/sessions/` | Done |
| `/clear` / `/new` | Reset store, session file, agent memory | Verify agent message array cleared | Done |
| `/resume` | Browse and load prior sessions | Interactive selector; `/resume last`, `/resume {id}` | Missing |
| `/rename` | Rename current session (≤100 chars) | Persist metadata | Missing |
| `/export` | Export session to markdown | Transcript + tool summary | Missing |
| Retention policy | Max sessions, retention days | `.jackal` or global config | Missing |

**Steps:**

1. Session index file listing sessions with id, name, cwd, timestamps.
2. `/resume` Ink overlay (list + preview).
3. Background auto-save timer (default 30s, nanocoder parity).
4. `/export` — markdown template with messages and tool calls.
5. Prune old sessions on startup per retention config.

**Maps to roadmap phase:** P3.

---

## A7. Context compression — **Phase P3**

Nanocoder: `reference/nanocoder/docs/features/context-compression.md`.

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| `/compact` | Manual compression | LLM summary (default) + mechanical fallback | Partial |
| `/compact --preview` | Preview without applying | | Missing |
| `/compact --restore` | Restore pre-compaction backup | Single backup slot | Missing |
| Auto-compact | Trigger at context % threshold | Config: threshold, strategy, notify | Missing |
| `/usage` | Visual context utilization | Token calculator + model window | Missing |
| `/context-max` | Set or inspect max context for session | CLI flag `--context-max` | Missing |

**Steps:**

1. Port `message-compression.ts` / `auto-compact.ts` patterns — LLM summariser prompt, mechanical regex fallback.
2. Pre-compaction backup in session dir.
3. Auto-compact hook in agent loop when usage > threshold.
4. `/usage` Ink widget (progress bar of context fill).
5. Wire `.jackal` keys: `autoCompact.enabled`, `threshold`, `strategy`.

**Maps to roadmap phase:** P3. Required for long Jac refactor sessions.

---

## A8. Checkpointing — **Phase P4**

Nanocoder: `reference/nanocoder/docs/features/checkpointing.md`.

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| `/checkpoint create [name]` | Snapshot conversation + git-tracked file changes | | Missing |
| `/checkpoint list` | List checkpoints with metadata | | Missing |
| `/checkpoint load [name]` | Restore files; prompt backup if dirty | | Missing |
| `/checkpoint delete <name>` | Remove checkpoint | | Missing |

**Steps:**

1. Store under `.jackal/checkpoints/` (gitignore by default).
2. On create: serialize messages, provider/model, list of modified files + contents (git diff baseline).
3. On load: restore files immediately; optional conversation restore requires session reload.
4. Backup prompt before destructive load.

**Maps to roadmap phase:** P4. Enables safe `/fix` and refactor experiments.

---

## A9. Task management — **Phase P4**

Nanocoder: `reference/nanocoder/docs/features/task-management.md`.

| Feature | Steps | Status |
|---------|-------|--------|
| `/tasks` list | | Missing |
| `/tasks add`, `/tasks remove`, `/tasks clear` | | Missing |
| Agent task tools | `create_task`, `update_task`, `list_tasks`, `delete_task` | Missing |
| Persist `.jackal/tasks.json` | Clear on `/clear` and startup (nanocoder behaviour) | Missing |

**Steps:**

1. Task store in adapter; expose to agent as tools.
2. Ink `/tasks` view in transcript or overlay.
3. Plan mode integration — agent creates tasks from numbered plan steps.

**Maps to roadmap phase:** P4. Pairs with plan mode and multi-step Jac workflows.

---

## A10. Subagents & orchestration — **Phase P5**

Nanocoder: `reference/nanocoder/docs/features/subagents.md`. Jackal already defines scout / architect / implementer in `subagents/agents/`.

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| Subagent definitions | Markdown + YAML frontmatter in `.jackal/agents/` or project `subagents/` | Port loader | Missing |
| `agent` tool | Delegate to subagent; isolated context; result only returned | Max 5 parallel | Missing |
| Saved chains | `.chain.md` workflows (scout → architect → implementer) | `chains/pipeline.chain.md` | Missing |
| Model overrides | Per-subagent model pins | `.jackal` `subagents` key | Missing |
| `/agents` | List, create, copy subagents | | Missing |

**Steps:**

1. Subagent loader reading frontmatter (name, description, model, tools).
2. `agent` tool implementation — spawn child session, filtered tools, return summary.
3. Chain runner for saved `.chain.md` files.
4. `/subagent-model` or config for model pins.
5. Register built-in Jac agents: scout, architect, implementer.

**Maps to roadmap phase:** P5 (also Tier 3 research item: multi-agent planner).

---

## A11. Extensibility — **Phase P5**

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| `.jackal` project config | `autocheck`, `verbose`, `plan`, `maxFixAttempts`, etc. | Expand keys; document schema | Partial |
| Custom slash commands | Markdown in `.jackal/commands/` with `{{params}}` | Nanocoder custom-commands pattern | Missing |
| Skills on demand | `skills/*/SKILL.md` loaded when task matches | Agent reads via read tool + skill index | Missing |
| Prompt templates | Reusable prompts from `prompts/` | `/template` or namespaced commands | Missing |
| `/init` | Analyze project; generate/update AGENTS.md | Optional `--force`, `--lean` | Missing |
| Provider / MCP wizards | Interactive setup | `/setup-providers`, `/setup-mcp` or `/login` + `/mcp` | Partial |

**Steps:**

1. Custom command loader — scan `.jackal/commands/*.md`, register dynamically.
2. Skill index in system prompt footer; agent instructed to read matching SKILL.md.
3. `/init` — run project analyzer (Jac files, jac.toml, entrypoints) → AGENTS.md template.
4. MCP setup wizard Ink flow (templates from nanocoder `mcp-templates.ts`).

**Maps to roadmap phase:** P5.

---

## A12. Non-interactive & automation — **Phase P6**

Nanocoder: `commands.md` § Non-Interactive Mode.

| Feature | Description | Steps | Status |
|---------|-------------|-------|--------|
| `jackal run "prompt"` | Headless single-shot; auto-accept default | Minimal stdout (no banner noise) | Missing |
| `--mode plan\|yolo\|auto-accept` | Override mode for run + interactive | | Missing |
| `--plain` | Pipe-friendly output for CI | | Missing |
| Exit code 1 | When tool approval required but mode won't grant | | Missing |
| Scheduler (optional) | Cron recurring agent tasks | Nanocoder `/schedule` | Missing |

**Steps:**

1. CLI entry in `jackal.sh` or bin: `run`, `--mode`, `--plain`.
2. Reuse adapter without Ink when stdout is not a TTY.
3. Document CI examples: `jackal run "fix jac check errors in main.jac"`.

**Maps to roadmap phase:** P6.

---

## A13. Keyboard & ergonomics — **Phase P2–P6** (ongoing)

Nanocoder: `reference/nanocoder/docs/features/keyboard-shortcuts.md`. Cross-cut; implement alongside related features.

| Action | Suggested binding | Phase |
|--------|-------------------|-------|
| Submit prompt | Enter | P1 ✓ |
| New line | Ctrl+J | P1 |
| Toggle dev mode | Shift+Tab | P2 |
| Cancel response | Esc | P1 |
| Clear input | Esc twice | P1 |
| Compact tool output | Ctrl+O | P1 |
| Explain selection | Ctrl-j e | P7 (Jac) |
| Fix diagnostics | Ctrl-j f | P7 (Jac) |
| Run check | Ctrl-j c | P7 (Jac) |
| Run tests | Ctrl-j t | P7 (Jac) |
| Paste multimodal context | Ctrl-j v | P8 |
| Jac command palette | Ctrl-j Ctrl-j | P7 |

**Steps:** Centralize keymap in shell; document in `/help` and README.

---

# Track B — Jac Differentiators

Jac-specific reasoning the agent must internalize:

* walkers, nodes, edges, object-spatial modeling, abilities
* graph traversal semantics, AI-native declarations
* Jac/Python interop, full-stack project structure
* Jac compiler/runtime failure modes

## B1. Project detection — **Phase P7**

When opened in a repo, detect:

* `*.jac` files, `jac.toml`, Python environment
* installed `jac` / `jaclang` / `jaseci` and version
* entrypoints: `main.jac`, `app.jac`, etc.
* backend / fullstack / client layout, tests, generated artifacts

| Command | Steps | Status |
|---------|-------|--------|
| `/jac-doctor` | Run detection; surface in TUI report | Partial |
| Project skill | `skills/project-skill/` for agent self-orientation | Missing |

**Steps:**

1. Port jac-doctor checks into `src/runtime/` (CLI probe, glob `.jac`, parse jac.toml).
2. Inject project summary into system prompt on session_start when Jac repo detected.
3. `.jackal` overrides for entrypoint and project type.

---

## B2. Jac toolchain loop — **Phase P7**

Thin adapter around Jac CLI (see Layer 2 architecture below).

| Command | Description | Steps | Status |
|---------|-------------|-------|--------|
| `/jac-check` | `jac check` → structured diagnostics in TUI | Parse to `JacDiagnostic[]`; display grouped by file | Partial |
| `/fix` | check → patch → re-check (capped) | Use MCP `validate_jac` when available; else CLI | Partial |
| Autocheck on edit | Re-validate `.jac` after write/edit | Hook on tool_result when `autocheck` enabled | Done |
| `/jac-test` | `jac test` + repair loop | Same bounded loop as fix | Missing |
| `/jac-format` | `jac format` | Optional autoformat from `.jackal` | Missing |
| `/jac-run` | `jac run` / entrypoint | Capture runtime errors as diagnostics | Missing |

**Diagnostic type:**

```ts
type JacDiagnostic = {
  file: string;
  line: number;
  column?: number;
  severity: "error" | "warning" | "info";
  code?: string;
  message: string;
  raw: string;
};
```

**Steps:**

1. Unified `runJacCommand(cmd)` in adapter with normalized stderr parser.
2. `/fix` — max attempts from `.jackal` `maxFixAttempts`; show diff before apply (normal mode).
3. `/jac-test` — parse test failures; feed into fix loop.
4. Autocheck hook also runs on MCP-validated edits.

**Exit criteria:** `/jac-check` surfaces errors; `/fix` resolves a known-broken `.jac` within retry cap.

---

## B3. Jac explanation mode — **Phase P7**

| Command | Purpose |
|---------|---------|
| `/jac explain walker` | Traversal semantics, state mutations |
| `/jac explain file` | Structure of nodes/edges/walkers in file |
| `/jac explain error` | Compiler message → fix guidance |
| `/jac explain graph` | Graph model from code or description |

**Steps:**

1. Prompt templates in `prompts/explain.md` + Jac MCP `explain_error`, `get_ast`, `graph_visualize`.
2. Wire slash variants to template + optional `@` selection context.
3. Mermaid ASCII rendering in transcript for graph explanations.

---

## B4. Jac project generation — **Phase P7**

| Command | Internal action |
|---------|-----------------|
| `/jac new api` | `jac create` API template |
| `/jac new fullstack` | fullstack template |
| `/jac new graph-app` | OSP-heavy template |
| `/jac new ai-service` | AI-native template |
| `/jac new walker-demo` | walker tutorial |
| `/create` | Interactive template picker (existing partial wrapper) |

**Steps:**

1. List templates via `jac create --list` or MCP `list_commands`.
2. Ink select overlay for template choice.
3. Post-create: run `/jac-doctor` + `/jac-check` automatically.

---

## B5. Python → Jac refactor — **Phase P8** (killer demo)

| Command | `/jac convert-python` |
|---------|-------------------------|
| Use case | Rewrite Python domain model as nodes/edges/walkers/abilities |
| Steps | 1. Extract domain model from Python via AST/`py_to_jac` MCP 2. Propose graph model (architect subagent) 3. Generate `.jac` + tests 4. `/jac-check` until clean |

**Maps to:** Tier 1 differentiator; Phase P8 after foundation stable.

---

## B6. OSP & graph modeling — **Phase P8**

| Feature | Description |
|---------|-------------|
| `/osp` | Turn domain description → nodes/edges/walkers |
| Graph modeling assistant | Natural language → graph schema + sample walkers |
| Walker debugger | Explain traversal paths and state mutations |
| Idiom reviewer | Detect "Python written in Jac" anti-patterns |
| `/jac review-idioms` | FR-9 patterns: arrays instead of edges, hidden AI calls, etc. |

**Steps:**

1. Port `/osp` workflow + `osp-skill`.
2. MCP `graph_visualize` + mermaid-renderer in transcript.
3. Idiom reviewer skill with check list from FR-9.

---

## B7. Multimodal & diagrams — **Phase P8**

| Source | Use |
|--------|-----|
| Clipboard / file image | Architecture screenshots |
| Mermaid / Graphviz | Diagram → Jac model |
| `/jac diagram-to-model` | Multimodal model → nodes/edges/walkers |

**Steps:** Image ingest in prompt builder; route to frontier model; validate output with `validate_jac`. Defer until P0–P7 reliable (see recommended sequence below).

---

## B8. Advanced Jac intelligence — **Phase P9** (Tier 2–3)

| Feature | Phase | Steps |
|---------|-------|-------|
| LSP tools | P9 | Port diagnostics, hover, rename, code_actions from legacy extension |
| AST-aware edits | P9 | MCP `get_ast`; structural search/replace |
| Graph execution visualizer | P9 | Walker trace → Mermaid/Graphviz |
| Agentic test generation | P9 | Tests from graph invariants |
| Local docs RAG | P9 | Versioned retrieval over Jac docs |
| Semantic synthesis / migration agent | P9+ | Research-grade (Tier 3) |

---

# Architecture (unchanged intent)

## Layer 1 — Agent runtime

Jackal runtime (`src/`) + jac-ink Ink shell.

Responsibilities: slash commands, keyboard bindings, context collectors, Jac CLI wrappers, diagnostics parsing, patch application, model routing, skill loading, subagents.

## Layer 2 — Jac toolchain adapter

Wraps: `jac check`, `run`, `test`, `format`, `lint`, `start`, `create`, `add`, `install`, `nacompile`.

## Layer 3 — Jac knowledge pack

Skills + docs (not bloated system prompt): syntax, OSP guide, walker patterns, AI-native examples, common errors, templates.

## Layer 4 — Multimodal context ingestion

Clipboard, images, terminal selection, `@file` regions, repo tree, diagnostics, AST/LSP, README/specs, diagrams.

## Layer 5 — Model routing

Fast models: syntax explanation, diagnostics triage, command suggestions.

Strong models: image-to-architecture, large refactors, ambiguous design.

---

# Feature map (tiers)

## Tier 0 — Required MVP (P0–P3 + P7 core)

| Feature | Track | Phase |
|---------|-------|-------|
| Runtime boot + Ink shell | A | P0–P1 |
| Core tools + MCP | A | P1 |
| Tool approval + plan mode | A | P2 |
| `@file` / `!cmd` context | A | P2 |
| Session save / resume | A | P3 |
| Context compression + `/usage` | A | P3 |
| `/jac-doctor`, `/jac-check`, `/fix`, autocheck | B | P7 |
| Jac skill pack + system prompt | B | P7 |

## Tier 1 — Differentiators (P5–P8)

| Feature | Track | Phase |
|---------|-------|-------|
| Subagents + chains | A | P5 |
| Custom commands + skills | A | P5 |
| Checkpointing + tasks | A | P4 |
| Python → Jac refactor | B | P8 |
| OSP / graph modeling assistant | B | P8 |
| Jac idiom reviewer | B | P8 |
| Full-stack generator | B | P7 |
| Multimodal diagram ingestion | B | P8 |
| `jackal run` CI mode | A | P6 |

## Tier 2 — Advanced (P9)

AST/LSP integration, graph visualizer, test generation, native compile advisor, local docs RAG.

## Tier 3 — Research (P9+)

Semantic synthesis, graph invariant verifier, multi-agent planner, runtime trace debugger, Jac migration agent.

---

# Phase summary (implementation order)

| Phase | Focus | Key deliverables |
|-------|--------|------------------|
| **P0** | Runtime skeleton | Adapter boot, auth, session, system prompt, smoke test |
| **P1** | Usable TUI + tools | Ink shell polish, tool timeline, read/write/edit/bash, lazy MCP |
| **P2** | Safety + context | Dev modes, tool approval, `@file`, `!cmd`, keyboard map |
| **P3** | Long sessions | `/resume`, auto-save, `/compact`, auto-compact, `/usage` |
| **P4** | Workflow depth | Checkpoints, task management |
| **P5** | Extensibility | Subagents, chains, custom commands, skills, `/init` |
| **P6** | Automation | `jackal run`, `--plain`, `--mode` |
| **P7** | Jac toolchain MVP | `/jac-doctor`, `/jac-check`, `/fix`, `/create`, explain, test/format |
| **P8** | Jac differentiators | `/convert-python`, `/osp`, idiom review, multimodal diagrams |
| **P9** | Advanced | LSP, AST edits, visualizer, RAG, migration |

---

# Recommended build sequence

Do **not** start with multimodal or Python→Jac until foundation is reliable.

### Stage 1 — Credible agent (P0–P2)

```txt
/jac-doctor
/jac-check
/fix          # with tool approval + plan mode
@src/foo.jac  # context input
```

Nanocoder parity targets: normal/auto-accept modes, `@file`, tool timeline, Esc cancel.

### Stage 2 — Daily driver (P3–P6)

```txt
/resume
/compact
/checkpoint create before-refactor
jackal run "add tests for walker X"
```

### Stage 3 — Jac MVP (P7)

Full toolchain loop with autocheck and bounded fix.

### Stage 4 — Killer demos (P8)

```txt
/jac convert-python
/jac diagram-to-model
/osp
```

### Stage 5 — Advanced (P9)

LSP, AST, visualizer, RAG.

---

# PRD essentials (abbreviated)

## Problem

Jac tooling is VS Code–centric. Terminal users lack a specialized agent with Jac toolchain loops, OSP knowledge, and diagnostic-aware repair.

## Non-goals

* Replace Jac compiler or LSP
* Full IDE, model hosting, cloud deploy, formal verification

## Core user stories

| ID | Story | Phase |
|----|-------|-------|
| US-1 | `/fix` runs check → patch → verify loop | P7 |
| US-2 | `/jac explain` teaches walkers/OSP | P7 |
| US-3 | `/jac convert-python` demo | P8 |
| US-4 | Domain description → graph model | P8 |
| US-5 | Diagram/screenshot → Jac | P8 |
| US-6 | Works in tmux/SSH/Nvim without VS Code | P0–P2 |
| US-7 | Resume long session after disconnect | P3 |
| US-8 | Safe experiment with checkpoint rollback | P4 |
| US-9 | CI: `jackal run "..."` | P6 |

---

# Non-functional requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Lightweight install: clone + `npm install` / `./jackal.sh` |
| NFR-2 | No VS Code dependency |
| NFR-3 | Jac version–aware docs/skills |
| NFR-4 | Transparent tool invocations (visible `jac check ...`) |
| NFR-5 | Safe patching: diff preview, backups, git-aware checkpoints |
| NFR-6 | Extensible: custom commands, skills, templates, model prefs |

---

# Best first technical milestone

An agent runtime that can:

1. Detect a Jac repo (`/jac-doctor`)
2. Run `jac check` and parse output
3. Ask the model for a patch (with user approval in normal mode)
4. Apply the patch
5. Rerun `jac check`

That is the minimum credible **Jac** coding agent. Terminal foundation (P0–P2) is the minimum credible **coding agent** of any kind.

Everything else compounds from there.

---

# Related docs

| Doc | Purpose |
|-----|---------|
| [`docs/NANOCODER-PARITY.md`](docs/NANOCODER-PARITY.md) | Full nanocoder vs Jackal feature matrix |
| [`docs/FEATURES.md`](docs/FEATURES.md) | Live status checklist |
| [`docs/PLAN.md`](docs/PLAN.md) | TUI build phases |
| [`docs/REMAINING_TUI_PLAN.md`](docs/REMAINING_TUI_PLAN.md) | Ink milestones M1–M6 |
| [`reference/nanocoder/docs/features/`](reference/nanocoder/docs/features/) | Terminal agent feature specs |
| [`AGENTS.md`](AGENTS.md) | Agent rules; jac-ink handoff |

---

# References

- [Jac CLI](https://docs.jaseci.org/reference/cli/)
- [Jac VS Code extension](https://github.com/jaseci-labs/jac-vscode)
- [Jaseci](https://github.com/jaseci-labs/jaseci)
- [Jac multimodal tutorials](https://docs.jaseci.org/tutorials/ai/multimodal/)
- [Nanocoder](https://github.com/Nano-Collective/nanocoder) — terminal agent reference implementation in this repo
