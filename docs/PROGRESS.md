# Jackal Roadmap Progress

Last updated: 2026-05-23

## Phase status

| Phase | Status | Notes |
|-------|--------|-------|
| **P0** | done | Smoke `--check`, lazy MCP, `scheduleMcpConnect` |
| **P1** | done | Tool rows, Ctrl+O, Esc/double-Esc, MCP status bar |
| **P2** | done | Dev modes, tool approval, `@file`/`!cmd`, `/explorer` overlay |
| **P3** | done | Session index, resume picker, auto-save, compact backup, `/usage`, auto-compact |
| **P4** | done | Checkpoints + tasks runtime + shell slash |
| **P5** | done | Subagents, chains, custom commands, skill index, `/init` |
| **P6** | done | `jackal run`, `--plain`, `--mode`, exit codes |
| **P7** | done | jac-cli, doctor, fix flow, format/test/run tools |
| **P8** | done | OSP, convert-python, idioms, diagram-to-model (text), Ctrl+j shortcuts |
| **P9** | deferred | Deep LSP, AST edits, RAG, migration agent |

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
| `/resume`, auto-save | done |
| `/compact`, `/usage` | done |
| Checkpoints | done |
| Tasks | done |
| Subagents | done |
| Custom commands | done |
| `jackal run` | done |
| `/explorer` | done |
| Scheduler | deferred |

## Jac differentiators (Track B)

| Feature | Status |
|---------|--------|
| `/jac-doctor`, `/jac-check` | done |
| `/fix` + autocheck | done |
| `/osp`, convert-python, idioms | done |
| `/jac explain`, diagram-to-model | done |
| Multimodal image ingest | deferred (P9+) |

## Runtime modules (`src/runtime/`)

`agent-session`, `auth`, `auto-compact`, `chains`, `checkpoints`, `context-input`, `context-usage`, `custom-commands`, `dev-mode`, `file-explorer`, `frontmatter`, `jac-cli`, `jac-doctor`, `jac-types`, `jac-workflows`, `lsp-tools`, `mcp-client`, `mermaid-render`, `project-config`, `project-init`, `session`, `session-index`, `skill-index`, `subagent-runner`, `subagents`, `system-prompt`, `task-tools`, `tasks`, `tool-approval`, `tools`, `agent-tool`

## Session log

- **2026-05-23:** Completed P2–P5 and P8 shell wiring: `/explorer`, resume picker, export-to-file, compact flags, `/init`, `/jac explain`, diagram-to-model, Ctrl+j Jac shortcuts. ROADMAP P0–P8 complete.
