# Jackal Roadmap — Master Game Plan

**Started:** 2026-05-23  
**Goal:** Complete ROADMAP.md P0–P8 and reach **nanocoder feature parity** on terminal agent foundation (Track A), then Jac differentiators (Track B).

## Strategy

1. **One file per phase** — `docs/phases/P{n}.md` holds tasks, exit criteria, and handoff notes.
2. **Live progress** — `docs/PROGRESS.md` updated after each phase milestone.
3. **Subagents** — Parallel workers per phase; parent merges and unblocks.
4. **Reference-first** — Port patterns from `reference/nanocoder/` before inventing.
5. **Consolidation** — Single runtime in `src/`; legacy `pi/extensions/` removed (see `docs/CONSOLIDATION_PLAN.md`).
6. **No jac-ink edits** — Runtime + `templates/shell.cl.jac` only.

## Build order (strict)

| Stage | Phases | Gate |
|-------|--------|------|
| 1 — Credible agent | P0 → P2 | `./jackal.sh`, modes, `@file`, tool timeline |
| 2 — Daily driver | P3 → P6 | `/resume`, `/compact`, checkpoints, `jackal run` |
| 3 — Jac MVP | P7 | `/jac-check`, `/fix`, doctor, autocheck |
| 4 — Killer demos | P8 | `/osp`, convert-python, idioms |
| 5 — Advanced | P9 | LSP, AST (defer until P0–P8 done) |

## Nanocoder parity checklist (Track A)

- [ ] P0: Smoke/CI boot, lazy MCP, graceful dispose
- [ ] P1: Tool detail rows, Ctrl+O, Esc/double-Esc
- [ ] P2: Dev modes, tool approval, `@file`, `!cmd`, `/explorer`
- [ ] P3: `/resume`, auto-save, `/compact`+backup, `/usage`, auto-compact
- [ ] P4: Checkpoints, `/tasks`
- [ ] P5: Subagents, chains, custom commands, skills, `/init`
- [ ] P6: `jackal run`, `--plain`, `--mode`

## Jac parity checklist (Track B)

- [ ] P7: `/jac-doctor`, `/jac-check`, `/fix`, test/format/run, explain
- [ ] P8: `/osp`, convert-python, idiom review, multimodal (basic)

## Subagent assignments

| Agent | Phase | Focus |
|-------|-------|-------|
| A | P0 | Smoke CLI, lazy MCP boot |
| B | P1 | Tool timeline UI in shell |
| C | P2 | Dev modes + approval queue |
| D | P2 | `@file`, `!cmd`, explorer |
| E | P3 | Session resume + auto-save |
| F | P3 | Context compression + `/usage` |
| G | P4 | Checkpoints + tasks |
| H | P5 | Subagents + extensibility |
| I | P6 | `jackal run` headless |
| J | P7 | Jac toolchain slash commands |
| K | P8 | OSP + convert-python + idioms |

## Files to touch (by layer)

| Layer | Path |
|-------|------|
| Runtime | `src/store.ts`, `src/adapter.ts`, `src/bridge.ts`, `src/runtime/*` |
| CLI | `jackal.sh`, `bin/jackal` (new) |
| Ink shell | `templates/shell.cl.jac` |
| Config | `.jackal` schema in `project-config.ts` |
| Docs | `docs/FEATURES.md`, `docs/PROGRESS.md` |

## Current focus

**2026-05-23:** P0–P2 and P6–P7 runtime complete. P3–P5 and P8 partial (Ink overlays and `/explorer` remain). P9 deferred.

See [`PROGRESS.md`](./PROGRESS.md) for live status.
