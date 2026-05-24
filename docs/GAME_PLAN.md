# Jackal Roadmap — Master Game Plan

**Started:** 2026-05-23  
**Completed:** 2026-05-23 (P0–P8)  
**Goal:** Complete ROADMAP.md P0–P8 and reach **nanocoder feature parity** on terminal agent foundation (Track A), then Jac differentiators (Track B).

## Strategy

1. **One file per phase** — `docs/phases/P{n}.md` holds tasks, exit criteria, and handoff notes.
2. **Live progress** — `docs/PROGRESS.md` updated after each phase milestone.
3. **Subagents** — Parallel workers per phase; parent merges and unblocks.
4. **Reference-first** — Port patterns from `reference/nanocoder/` before inventing.
5. **Consolidation** — Single runtime in `src/`; legacy `pi/extensions/` removed (see `docs/CONSOLIDATION_PLAN.md`).
6. **No jac-ink edits** — Runtime + `templates/shell.cl.jac` only.

## Build order (strict)

| Stage | Phases | Gate | Status |
|-------|--------|------|--------|
| 1 — Credible agent | P0 → P2 | `./jackal.sh`, modes, `@file`, tool timeline | ✅ |
| 2 — Daily driver | P3 → P6 | `/resume`, `/compact`, checkpoints, `jackal run` | ✅ |
| 3 — Jac MVP | P7 | `/jac-check`, `/fix`, doctor, autocheck | ✅ |
| 4 — Killer demos | P8 | `/osp`, convert-python, idioms, diagram-to-model | ✅ |
| 5 — Advanced | P9 | LSP depth, AST, RAG (defer) | ⏸ |

## Nanocoder parity checklist (Track A)

- [x] P0: Smoke/CI boot, lazy MCP, graceful dispose
- [x] P1: Tool detail rows, Ctrl+O, Esc/double-Esc
- [x] P2: Dev modes, tool approval, `@file`, `!cmd`, `/explorer`
- [x] P3: `/resume`, auto-save, `/compact`+backup, `/usage`, auto-compact
- [x] P4: Checkpoints, `/tasks`
- [x] P5: Subagents, chains, custom commands, skills, `/init`
- [x] P6: `jackal run`, `--plain`, `--mode`

## Jac parity checklist (Track B)

- [x] P7: `/jac-doctor`, `/jac-check`, `/fix`, test/format/run, explain
- [x] P8: `/osp`, convert-python, idiom review, diagram-to-model (text)

## Current focus

**P9 deferred:** semantic synthesis, local docs RAG, graph trace visualizer, migration agent.

See [`PROGRESS.md`](./PROGRESS.md) for live status.
