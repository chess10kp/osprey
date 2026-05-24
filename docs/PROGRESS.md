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

## Source modules (`src/`)

| Directory | Responsibility |
|-----------|----------------|
| `core/` | Adapter, immutable store, event bridge, headless UI context |
| `auth/` | Provider credentials, login state machine, auth actions |
| `session/` | Session persistence, agent session loop, auto-compact |
| `agent/` | Tool registry, MCP client, dev/plan mode, approval queue |
| `config/` | `.jackal` project config loader |
| `jac/` | Jac CLI helpers, doctor, workflows, LSP tools |
| `workflow/` | Tasks, checkpoints, context input expansion, custom commands |
| `orchestration/` | Subagents, chains, frontmatter parsing |
| `project/` | Project init, file explorer, skill index |
| `ui/` | Slash-command autocomplete |
| `render/` | Mermaid ASCII renderer |
| `cli/` | Headless `jackal run` entry |

## Session log

- **2026-05-23:** Completed P2–P5 and P8 shell wiring: `/explorer`, resume picker, export-to-file, compact flags, `/init`, `/jac explain`, diagram-to-model, Ctrl+j Jac shortcuts. ROADMAP P0–P8 complete.
