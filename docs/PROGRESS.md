# Jackal Roadmap Progress

Last updated: 2026-05-23

## Phase status

| Phase | Status | Notes |
|-------|--------|-------|
| **P0** | done | Smoke `--check`, lazy MCP, `scheduleMcpConnect` |
| **P1** | done | Tool rows (args/duration), Ctrl+O compact, Esc/double-Esc, MCP status bar |
| **P2** | done | Dev modes, tool approval, `@file`/`!cmd` expand, Shift+Tab |
| **P3** | partial | Session index, resume, auto-save, compact backup; Ink picker overlay TODO |
| **P4** | partial | Checkpoints + tasks runtime; slash wired via facade |
| **P5** | partial | Subagents, chains, custom commands, `agent` tool |
| **P6** | done | `jackal run`, `--plain`, `--mode`, exit codes |
| **P7** | done | jac-cli, doctor, fix flow, format/test tools |
| **P8** | partial | OSP/convert-python/idioms workflows; multimodal deferred |
| **P9** | deferred | LSP, AST, RAG |

## Nanocoder parity (Track A)

| Feature | Status |
|---------|--------|
| Runtime boot + auth | done |
| Ink TUI + streaming | done |
| read/write/edit/bash | done |
| Jac MCP (lazy) | done |
| Dev modes + approval | done |
| `@file` / `!cmd` | done |
| Tool timeline | done |
| `/resume`, auto-save | partial (no full picker UI) |
| `/compact`, `/usage` | partial |
| Checkpoints | partial |
| Tasks | partial |
| Subagents | partial |
| Custom commands | done |
| `jackal run` | done |
| `/explorer` | missing |
| Scheduler | deferred |

## Jac differentiators (Track B)

| Feature | Status |
|---------|--------|
| `/jac-doctor`, `/jac-check` | done |
| `/fix` + autocheck | done |
| `/osp`, convert-python, idioms | partial (runtime prompts) |
| Multimodal diagrams | deferred |

## Runtime modules (`src/runtime/`)

`agent-session`, `auth`, `chains`, `checkpoints`, `cli-run` (via `src/cli-run.ts`), `context-input`, `context-usage`, `custom-commands`, `dev-mode`, `jac-cli`, `jac-doctor`, `jac-types`, `jac-workflows`, `mcp-client`, `project-config`, `session`, `session-index`, `subagent-runner`, `subagents`, `system-prompt`, `task-tools`, `tasks`, `tool-approval`, `tools`, `agent-tool`

## Session log

- **2026-05-23:** Master game plan + phase files P0–P9. Parallel subagents implemented P0–P8 runtime. Shell/facade wired for modes, approval, slash commands, keyboard map. Build + smoke pass.

## Next (if continuing)

1. Ink `/explorer` overlay (P2)
2. Session resume picker UI (P3)
3. Auto-compact threshold hook (P3)
4. `/init` AGENTS.md generator (P5)
5. Skill index in system prompt footer (P5)
6. P9 LSP port from `pi-lsp-extension`
