# Nanocoder Feature Parity — Jackal Scope

> **Legacy parity matrix.** Use this as input to the all-Jac Roadmap N3 cutover checklist, not as the forward implementation plan. P0–P9 references below are historical; current phases are in [`../ROADMAP.md`](../ROADMAP.md).

**Reference:** [`reference/nanocoder/`](../reference/nanocoder/) (vendored upstream)  
**Last reviewed:** 2026-05-24

Nanocoder is Jackal's baseline for what a complete terminal coding agent looks like. This document scopes every major nanocoder feature area, maps it to Jackal's implementation, and records intentional gaps.

**Legend:** ✅ Done · 🟡 Partial · ❌ Missing · ➖ N/A (different by design)

---

## Executive summary

| Area | Parity | Notes |
|------|--------|-------|
| **Runtime & boot** (P0) | ✅ | Headless adapter, auth, lazy MCP, smoke `--check` |
| **Ink shell & input** (P1) | 🟡 | Core TUI done; markdown text wrapping still missing |
| **Core tools** (P1) | 🟡 | read/write/edit/bash/glob + Jac MCP; no dedicated git/file-op tools |
| **Context syntax** (P2) | 🟡 | `@file`, line ranges, `!cmd`, `/explorer`; no `.gitignore` parser |
| **Dev modes & approval** (P2) | ✅ | All four modes + queue + select confirmation UI |
| **Sessions** (P3) | ✅ | Index, `/resume`, auto-save, retention, export, rename |
| **Context compression** (P3) | ✅ | LLM summary + mechanical fallback, auto-compact, `/usage` widget |
| **Checkpoints & tasks** (P4) | ✅ | Runtime + slash commands + Ink overlays |
| **Subagents & extensibility** (P5) | ✅ | Chains, custom commands, skills, `/init` |
| **Non-interactive run** (P6) | ✅ | `jackal run`, `--mode`, `--plain`, exit codes |
| **Jac differentiators** (P7–P8) | ✅ | Jackal-specific; no nanocoder equivalent |
| **Advanced nanocoder** | ❌ | Scheduler, tune, custom tools, VS Code bridge, model DB |

**Bottom line:** Jackal has **Track A foundation parity** (ROADMAP P0–P8). Remaining nanocoder gaps are mostly **power-user extensibility** (scheduler, tune, custom tools), **granular built-in tools** (git suite, file ops), and **TUI polish** (rich approval dialog, task/checkpoint views, streaming bash output).

---

## 1. Runtime & boot

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| Headless agent loop | `pi-agent-core` | `JackalAgentSession` in `src/session/` | ✅ |
| Immutable UI store | React state | `AgentStore` + `bridgeEvents` | ✅ |
| Auth + model picker | pi-ai OAuth/API keys | `src/auth/` | ✅ |
| System prompt | `AGENTS.md` + modular assembly | `pi/SYSTEM.md` + skill index | ✅ |
| Fast TUI boot | Lazy subsystem init | `scheduleMcpConnect` after first frame | ✅ |
| Smoke / CI path | CLI harness | `./jackal.sh --check`, `jackal run --check` | ✅ |
| Graceful dispose | Shutdown manager | SIGINT + `/exit`; no formal lifecycle manager | 🟡 |
| Structured logging | pino + redaction + correlation IDs | Console only | ❌ |
| Directory trust prompt | First-run safety | Not implemented | ❌ |
| Update checker | `/update` | Not implemented | ❌ |

**Nanocoder refs:** `reference/nanocoder/docs/features/index.md`, `source/cli.tsx`

---

## 2. Ink shell & input

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| Boot / error screen | Yes | `shell.cl.jac` | ✅ |
| Welcome banner | Yes | `welcomemsg.cl.jac` | ✅ |
| Status bar | Mode, model, context % | `statusbar.cl.jac` + inline bar in shell | ✅ |
| Message transcript | Scrollback | Done | ✅ |
| Streaming display | Tail-truncated plain → full MD on finalize | `streammsg.cl.jac` / `asstmsg.cl.jac` | ✅ |
| Markdown rendering | chalk + cli-highlight + cli-table3 + wrap-ansi | `templates/markdown.mjs` (no wrap-ansi yet) | 🟡 |
| Table rendering | cli-table3 | `parseMarkdownTable()` in `markdown.mjs` | ✅ |
| Text wrapping (ANSI-safe) | wrap-ansi + continuation trim | `templates/text-wrapping.mjs` | ✅ |
| Multiline input | Ctrl+J | Ctrl+J / Shift+Enter | ✅ |
| Slash routing + completions | Full registry | `src/ui/completions.ts` + shell | ✅ |
| Auth overlays | Provider/OAuth/key/model pickers | `authflow.cl.jac` | ✅ |
| Dialog overlays | Select/confirm/input | `ExtensionUIContext` | ✅ |
| Tool timeline | Expandable rows, Ctrl+O | `toolline.cl.jac` | ✅ |
| Tool approval UI | Rich expandable dialog | `ToolConfirmationOverlay` + formatter previews | ✅ |
| Usage display | Visual context bar | Status bar + `UsageDetailOverlay` | ✅ |
| Task list display | In-transcript visualization | `TasksOverlay` via `/tasks` | ✅ |
| Checkpoint selector | Ink component | `CheckpointOverlay` via `/checkpoint` | ✅ |
| Bash progress | Streaming output during run | Result shown after completion | ❌ |
| Streaming reasoning | Chain-of-thought display | Not implemented | ❌ |
| Security disclaimer | First-run component | Not implemented | ❌ |
| Keyboard shortcuts | Full keymap doc | Esc, Esc×2, Shift+Tab, Ctrl+O, Ctrl+j Jac shortcuts | 🟡 |

**Nanocoder refs:** `reference/nanocoder/docs/features/keyboard-shortcuts.md`, `source/markdown-parser/`, `source/components/`

---

## 3. Context input syntax

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| `@file` mentions | Fuzzy autocomplete | Prefix rank in `completions.ts` | 🟡 |
| `@file:10-20` line ranges | Yes | `src/workflow/context-input.ts` | ✅ |
| `!command` inline bash | Output → context | `context-input.ts` | ✅ |
| `/explorer` overlay | Tree, Space select, token estimate | `file-explorer.ts` + shell overlay | ✅ |
| Gitignore-aware search | Parses `.gitignore` | `src/project/gitignore.ts` + walk filter | ✅ |
| Fuzzy file matching | Dedicated fuzzy util | Simple rank function | 🟡 |
| Token warn on large `@` | 10k+ token warning | `formatTokenEstimate()` in explorer | ✅ |

**Nanocoder refs:** `reference/nanocoder/docs/features/commands.md`, `source/context/file-mention-handler.ts`

---

## 4. Development modes & tool approval

| Mode | Nanocoder | Jackal | Status |
|------|-----------|--------|--------|
| Normal | Confirm each tool | Default | ✅ |
| Auto-accept | Bash/destructive still prompt | `src/agent/dev-mode.ts` | ✅ |
| Yolo | All tools auto-run | Done | ✅ |
| Plan | Read-only tools only | Tool filter in plan mode | ✅ |
| Shift+Tab cycle | Yes | Shell handler | ✅ |
| `--mode` CLI flag | Yes | `jackal run --mode`, `.jackal` `mode` key | ✅ |
| Tool approval queue | Rich UI | `approval-display.ts` + `ToolConfirmationOverlay` | ✅ |
| Destructive op detection | Bash/git gates | Session permissions | 🟡 |
| Subagent approval | Separate queue | `subagent-approval.ts` | ✅ |

**Nanocoder refs:** `reference/nanocoder/docs/features/development-modes.md`

---

## 5. Session lifecycle

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| Auto-save (30s default) | Yes | `src/session/session.ts` timer | ✅ |
| Session index | id, name, cwd, timestamps | `src/session/session-index.ts` | ✅ |
| `/resume` picker | Interactive overlay | `ResumePickerOverlay` in shell | ✅ |
| `/resume last` / by id / index | Yes | Adapter `resumeSession()` | ✅ |
| `/rename` | ≤100 chars | Done | ✅ |
| `/export` markdown | Transcript export | `.jackal/exports/` | ✅ |
| Retention policy | maxCount + days | `.jackal` `sessions` config; prune on startup | ✅ |
| `/clear` / `/new` | Reset store + agent memory | Done | ✅ |
| Chat history browser | Past conversations UI | `/resume` only | 🟡 |

**Nanocoder refs:** `reference/nanocoder/docs/features/session-management.md`

---

## 6. Context compression

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| `/compact` LLM summary | Default strategy | `src/session/llm-compact.ts` | ✅ |
| `/compact --mechanical` | Regex fallback | `src/session/auto-compact.ts` | ✅ |
| `/compact --preview` | Preview without apply | Done | ✅ |
| `/compact --restore` | Single backup slot | `compaction-backup.json` | ✅ |
| Auto-compact at threshold | Configurable % + strategy | `.jackal` `autoCompact` | ✅ |
| `/usage` widget | Visual breakdown | `UsageDetailOverlay` + status bar | ✅ |
| `/context-max` + CLI flag | Override window size | Done | ✅ |
| Model-aware token counting | OpenAI/Anthropic/Llama tokenizers | chars/4 heuristic in `context-usage.ts` | 🟡 |
| Message compression | Shrink message bodies | Drop old messages / summarize | 🟡 |
| Aggressive compact preset | 40% threshold via `/tune` | No `/tune` command | ❌ |

**Nanocoder refs:** `reference/nanocoder/docs/features/context-compression.md`, `reference/nanocoder/docs/features/tune.md`

---

## 7. Checkpoints & tasks

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| `/checkpoint create/list/load/delete` | Full workflow | `src/workflow/checkpoints.ts` | ✅ |
| File snapshot on checkpoint | Git-tracked diff baseline | Done | ✅ |
| `/tasks` slash commands | add/remove/clear/list | `src/workflow/tasks.ts` | ✅ |
| Agent task tools | create/update/list/delete | Registered in tool registry | ✅ |
| Persist `.jackal/tasks.json` | Clears on `/clear` | Done | ✅ |
| Ink task visualization | In-transcript component | `TasksOverlay` | ✅ |
| Ink checkpoint selector | Overlay component | `CheckpointOverlay` (+ backup confirm on load) | ✅ |

**Nanocoder refs:** `reference/nanocoder/docs/features/checkpointing.md`, `reference/nanocoder/docs/features/task-management.md`

---

## 8. Subagents & orchestration

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| Subagent definitions | `.nanocoder/agents/*.md` | `pi/.pi/agents/` + project overrides | ✅ |
| `agent` tool | Isolated context, result only | `src/orchestration/subagents.ts` | ✅ |
| Saved chains | Workflow files | `pi/chains/*.chain.md` | ✅ |
| Model overrides | Per-subagent pins | `.jackal` `subagents` key | ✅ |
| `/agents` list/create | Yes | `/agents` list; no AI-assisted create | 🟡 |
| Parallel subagents | Max 5 | Supported | ✅ |

**Nanocoder refs:** `reference/nanocoder/docs/features/subagents.md`

---

## 9. Extensibility

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| Project config | `agents.config.json` | `.jackal` JSON | ✅ |
| Custom slash commands | `.nanocoder/commands/*.md` | `.jackal/commands/*.md` | ✅ |
| Custom tools | `.nanocoder/tools/*.md` — callable with schema | Not implemented (commands are prompt-only) | ❌ |
| Skills on demand | Skill index | `pi/skills/` + system prompt catalog | ✅ |
| Prompt templates | Reusable prompts | `pi/prompts/` + `/jac explain` variants | ✅ |
| `/init` AGENTS.md | Project analyzer | `src/project/project-init.ts` | ✅ |
| Provider setup wizard | `/setup-providers` | `/login` flow only | 🟡 |
| MCP setup wizard | `/setup-mcp` | Manual `pi/mcp.json`; `/mcp` status | 🟡 |
| Modular prompt builder | Runtime assembly | Static `SYSTEM.md` | 🟡 |
| Config env substitution | `${ENV}` in config | Not implemented | ❌ |
| Tool calling XML fallback | For non-native models | Relies on provider native tools | ❌ |

**Nanocoder refs:** `reference/nanocoder/docs/features/custom-commands.md`, `reference/nanocoder/docs/features/custom-tools.md`

---

## 10. Built-in agent tools

Nanocoder ships many single-purpose tools. Jackal consolidates most file/shell/git work into **bash** + **glob** + **Jac MCP**.

### Core file & shell

| Nanocoder tool | Jackal equivalent | Status |
|----------------|-------------------|--------|
| `read_file` | `read` | ✅ |
| `write_file` | `write` | ✅ |
| `string_replace` | `edit` | ✅ |
| `execute_bash` | `bash` | ✅ |
| `find_files` | `glob` | ✅ |
| `search_file_contents` | bash `grep` | 🟡 via bash |
| `list_directory` | bash `ls` / glob | 🟡 via bash |
| `copy_file`, `move_file`, `delete_file`, `create_directory` | bash `cp/mv/rm/mkdir` | 🟡 via bash |
| `string_replace_preview` | Not implemented | ❌ |

### Git (11 tools)

| Nanocoder | Jackal | Status |
|-----------|--------|--------|
| git-add, branch, commit, diff, log, pull, push, reset, stash, status, pr | Generic `bash` | 🟡 via bash |

### Web & research

| Nanocoder | Jackal | Status |
|-----------|--------|--------|
| Web search (Brave API) | Not built-in; could add MCP server | ❌ |
| Fetch URL → markdown | Not built-in | ❌ |
| `ask_question` (mid-turn user prompt) | Not implemented | ❌ |

### LSP

| Nanocoder | Jackal | Status |
|-----------|--------|--------|
| `lsp_get_diagnostics` (live LSP server) | Jac CLI + grep fallbacks in `src/jac/lsp-tools.ts` | 🟡 |
| Full LSP tool suite | diagnostics, hover, definition, references | ✅ |

### Other

| Nanocoder | Jackal | Status |
|-----------|--------|--------|
| `agent` (subagent) | `agent` tool | ✅ |
| Task tools | create/update/list/delete_task | ✅ |
| `compact_context` | `/compact` + auto-compact | ✅ |
| `mermaid` | `mermaid` tool | ✅ |
| Jac MCP (85 tools) | Auto-discovered via `jac mcp` | ✅ (Jackal-specific) |

**Nanocoder refs:** `reference/nanocoder/source/tools/`

---

## 11. Integrations (nanocoder-only or deferred)

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| **Scheduler / cron** | `/schedule create/add/start` | Not planned for v1 | ❌ |
| **Tune system** | `/tune` — tool profiles, model params, aggressive compact | Not implemented | ❌ |
| **VS Code extension bridge** | WebSocket diff preview, editor context | Not planned (terminal-first) | ➖ |
| **Model database** | `/model-database` OpenRouter browse | pi-ai model picker only | ❌ |
| **Provider-specific auth** | ChatGPT Codex, GitHub Copilot OAuth | Generic pi-ai providers | 🟡 |
| **Interactive wizards** | Provider + MCP step-by-step | Partial via `/login` | 🟡 |
| **Desktop notifications** | OS + in-TUI | `notify()` in UI context | 🟡 |
| **MCP config loader** | `.nanocoder/mcp.json` schema | `pi/mcp.json` (Jac server only today) | 🟡 |

**Nanocoder refs:** `reference/nanocoder/docs/features/scheduler.md`, `tune.md`, `vscode-extension.md`

---

## 12. Infrastructure utilities

| Utility | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| Command injection guard | Security scanner for bash | Not implemented | ❌ |
| Gitignore parser | Respects ignore rules | Hardcoded skip list | 🟡 |
| Fuzzy matching | File autocomplete | Simple rank | 🟡 |
| File cache | Read caching | Not implemented | ❌ |
| File type detector | MIME/extension hints | Not implemented | ❌ |
| ANSI truncation | Safe truncate for tool output | `tool-output-limit.ts` | 🟡 |
| Tool calling parser (XML) | Non-native model fallback | Not implemented | ❌ |
| Non-interactive markdown render | `--plain` flatten | `jackal run --plain` | ✅ |

---

## 13. Non-interactive mode

| Feature | Nanocoder | Jackal | Status |
|---------|-----------|--------|--------|
| `run "prompt"` | `nanocoder run` | `jackal run` | ✅ |
| Default auto-accept in run | Yes | Yes | ✅ |
| `--mode plan\|yolo\|auto-accept` | Yes | Yes | ✅ |
| `--plain` pipe-friendly output | Yes | Yes | ✅ |
| Exit code 1 on blocked approval | Yes | Yes | ✅ |

**Nanocoder refs:** `reference/nanocoder/docs/features/commands.md` § Non-Interactive Mode

---

## Recommended priorities (post P0–P8)

Ordered by impact for daily Jac development:

| Priority | Gap | Rationale |
|----------|-----|-----------|
| **P2-polish** | ~~Markdown text wrapping~~ | Done (`text-wrapping.mjs`) |
| **P2-polish** | ~~Rich tool approval dialog~~ | Done (`approval-display.ts` + banner) |
| **P2-polish** | ~~`.gitignore`-aware file listing~~ | Done (`gitignore.ts`) |
| **P4-polish** | ~~Task/checkpoint Ink overlays~~ | Done |
| **Optional** | Custom tools (`.jackal/tools/*.md`) | Lightweight CLI wrappers without full MCP |
| **Optional** | `/tune` for small local models | Tool profile + aggressive compact for 7B models |
| **Defer** | Scheduler, VS Code bridge, model database | Out of Jackal v1 scope per FEATURES.md |

---

## Related docs

- [FEATURES.md](./FEATURES.md) — Jackal required-feature checklist
- [ROADMAP.md](../ROADMAP.md) — phased delivery (P0–P9)
- [PROGRESS.md](./PROGRESS.md) — live phase status
- [phases/P3.md](./phases/P3.md) — session + compaction detail
- [reference/nanocoder/docs/features/index.md](../reference/nanocoder/docs/features/index.md) — upstream feature tour
