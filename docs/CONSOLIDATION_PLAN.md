# Jackal Consolidation Plan

**Goal:** One runtime (`src/`), one Jac toolchain surface (MCP for LLM + host CLI for hooks), nanochat-style vertical slices — no duplicate Pi extension, no god-object adapter, no overlapping agent tools.

**Inspired by:** [karpathy/nanochat](https://github.com/karpathy/nanochat) — single path, one copy of each idea, scripts/modules by concern, tests on hot paths.

**Out of scope:** jac-ink / jaclang / shim edits (human-owned per `AGENTS.md`).

---

## Principles

| nanochat pattern | Jackal target |
|------------------|---------------|
| `scripts/chat_cli.py` = thin entry, linear flow | `jackal.sh` + `cli-run.ts` + `templates/shell.cl.jac` call `src/` directly |
| `nanochat/engine.py` = one job | `agent-session.ts` owns loop; `bridge.ts` owns store sync; no third orchestration layer |
| No giant config trees | `.jackal` JSON + `dev-mode.ts` constants; delete duplicate plan whitelists |
| One copy of parsing/helpers | `jac-cli.ts` only; delete `pi/extensions/jackal/check.ts` |
| Tests on inference hot path | Vitest on `parseJacCheckOutput`, `bridgeEvents`, smoke boot |

---

## Phases (strict order)

### Phase 0 — Freeze legacy (1 PR)

**Do first.** Stop the bleed.

- [x] Remove `./jackal.sh --pi` and `JACKAL_CLASSIC_PI` code paths (or hard-error with migration message)
- [x] Delete import from `pi/extensions/jackal/commands.ts` → `src/adapter.js` (smoke command moves to `jackal run --check` only)
- [x] Add CI gate: `npm run check` / `./jackal.sh --check`
- [x] Update `AGENTS.md`, `COMMANDS_AND_INFO.txt`, `README.md` — one launch path only

**Exit:** No documented way to boot Pi extension; smoke still green.

---

### Phase 1 — Delete duplicate extension tree (1 PR)

Remove the entire Pi extension implementation. **Do not** delete config assets under `pi/`.

| Path | Action | Notes |
|------|--------|-------|
| `pi/extensions/jackal-toolchain.ts` | **DELETE** | Done |
| `pi/extensions/jackal/commands.ts` | **DELETE** | Done |
| `pi/extensions/jackal/hooks.ts` | **DELETE** | Autocheck/plan hooks → port gaps to `agent-session.ts` (Phase 3) |
| `pi/extensions/jackal/check.ts` | **DELETE** | Done |
| `pi/extensions/jackal/types.ts` | **DELETE** | Done |
| `pi/extensions/jackal/plan-mode.ts` | **DELETE** | Merge whitelist into `dev-mode.ts` (Phase 2) |
| `pi/extensions/jackal/config.ts` | **DELETE** | Done |
| `pi/extensions/jackal/settings.ts` | **DELETE** | Subagent pins live in `src/runtime/subagents.ts` + `pi/settings.json` |
| `package.json` `pi.extensions` | **DELETE** | Done |

**Keep under `pi/` (config bundle, not runtime):**

| Path | Action |
|------|--------|
| `pi/SYSTEM.md` | **KEEP** (later: move to `jackal/SYSTEM.md` to match docs) |
| `pi/mcp.json` | **KEEP** — `mcp-client.ts` reads `pi/mcp.json` |
| `pi/skills/**` | **KEEP** — loaded by workflows / future skill injection |
| `pi/prompts/**` | **KEEP** — `jac-workflows.ts` reads these |
| `pi/.pi/agents/**` | **KEEP** — `subagents.ts` package defaults |
| `pi/chains/**` | **KEEP** — `chains.ts` package defaults |
| `pi/settings.json`, `pi/auth.json` | **KEEP** — auth + model defaults |
| `pi/sessions/**` | **KEEP** (gitignore) — user data |

**Exit:** `pi/extensions/` gone; `npm run build:agent` + `./jackal.sh --check` pass.

---

### Phase 2 — Single source of truth for config & plan mode (1 PR)

| Path | Action | Merge target |
|------|--------|--------------|
| `src/runtime/dev-mode.ts` | **KEEP** | Canonical `PLAN_MODE_TOOLS`, approval policy |
| `pi/extensions/jackal/plan-mode.ts` | **DELETE** (Phase 1) | Tool lists + step extraction → see below |
| — | **NEW** `src/runtime/plan-mode.ts` | Port `extractPlanSteps`, `[DONE:n]` parsing, plan status from legacy hooks |
| `src/runtime/project-config.ts` | **KEEP** | Single `.jackal` loader |
| `src/runtime/jac-types.ts` | **KEEP** | Single `JacDiagnostic`, `fingerprintErrors` |
| `pi/extensions/jackal/types.ts` | **DELETE** (Phase 1) | Session state → instance fields on `JackalAgentSession` |

**Plan-mode tool whitelist (canonical):**

```
read, agent, validate_jac, check_syntax, explain_error, search_docs,
get_resource, get_ast, graph_visualize, list_examples, get_example,
create_task, update_task, list_tasks, delete_task
```

No `bash` in plan mode (legacy Pi list allowed it — drop).

**Exit:** One whitelist; plan step tracking lives in `src/runtime/plan-mode.ts` + session hooks.

---

### Phase 3 — Slim adapter; session owns behavior (2 PRs)

**Problem:** `adapter.ts` (583 LOC) exposes ~40 `actions.*` methods — parallel API to `JackalAgentSession`.

#### 3a — Split adapter

| Path | Action | Role after |
|------|--------|------------|
| `src/adapter.ts` | **SHRINK** | `createNextAgent()` returns `{ store, uiContext, authFlow, authActions, session, dispose }` |
| — | **NEW** `src/runtime/slash-handlers.ts` | Pure functions: doctor, check, fix, osp, checkpoint, tasks — called from shell or `custom-commands.ts` |
| `templates/jackal_agent_facade.mjs` | **REFACTOR** | Call `session.*` / imported handlers, not `actions.runFixFlow` bag |
| `templates/shell.cl.jac` | **REFACTOR** | Wire slash commands to handlers via facade |

#### 3b — Move autocheck from deleted hooks

Port from `pi/extensions/jackal/hooks.ts`:

| Behavior | New home |
|----------|----------|
| Track `.jac` writes/edits | `agent-session.ts` `beforeToolCall` / tool result listener |
| End-of-turn autocheck | `agent-session.ts` on `agent_end` |
| Autoformat after edit | `tools.ts` write/edit execute (already partial) + config flag |
| Plan `[DONE:n]` markers | `plan-mode.ts` + session turn-end hook |

**Exit:** `adapter.ts` < 200 LOC; facade exposes session, not god-object.

---

### Phase 4 — One Jac toolchain surface for the LLM (1 PR)

**Rule:** Host-side CLI (`jac-cli.ts`) for hooks/autocheck/headless. **MCP only** for LLM-callable Jac tools.

| Tool in `src/runtime/tools.ts` | Action |
|--------------------------------|--------|
| `read`, `write`, `edit`, `bash` | **KEEP** |
| `agent` (subagent) | **KEEP** |
| Task tools (`create_task`, …) | **KEEP** |
| `jac_cli` | **KEEP** (escape hatch: arbitrary `jac` subcommands) |
| `jac_check` | **DELETE** — use MCP `validate_jac` / `check_syntax` |
| `jac_doctor` | **DELETE** — slash `/jac-doctor` only (host) |
| `jac_format` | **DELETE** — MCP or `jac_cli format` |
| `jac_test` | **DELETE** — MCP `execute_command` or `jac_cli test` |
| `jac_create`, `jac_list_templates` | **DELETE** — slash `/create` + `jac_cli` |
| `jac_fix` | **DELETE** — slash `/fix` runs host loop |
| `compact_context` | **DELETE** until implemented — no stub tools |

**MCP wiring:** `mcp-client.ts` stays; ensure lazy connect on first turn (P0).

**Exit:** `createCoreTools()` returns ≤ 8 tools + MCP dynamic tools + task tools.

---

### Phase 5 — Vertical slice modules (1–2 PRs)

Split like nanochat `scripts/` — one workflow per file:

| New module | Responsibility | Port from |
|------------|----------------|-----------|
| `src/runtime/jac-doctor.ts` | **KEEP** (already exists) | — |
| `src/runtime/jac-cli.ts` | **KEEP** | absorb any remaining check.ts helpers |
| `src/runtime/jac-fix.ts` | **NEW** | `/fix` loop from `agent-session.runFixFlow` + legacy `registerJacFix` |
| `src/runtime/jac-workflows.ts` | **KEEP** | osp, convert-python, idioms |
| `src/runtime/checkpoints.ts` | **KEEP** | — |
| `src/runtime/tasks.ts` | **KEEP** | — |
| `src/runtime/custom-commands.ts` | **KEEP** | project `.jackal/commands/*.md` |

**`/fix` behavior fix (required):**

Current: check → format → prompt agent once → return.

Target: bounded loop (config `maxFixAttempts`, default 3):

1. `jac check`
2. If clean → done
3. If same fingerprint as last attempt → stop (no progress)
4. `jac format` affected files
5. Re-check; if clean → done
6. Prompt agent with diagnostics; **wait for agent_end**
7. Goto 1 until cap

Rename to `/fix` only when loop is real; until then expose as `/check-and-fix` in help text.

**Exit:** P7 checklist in `docs/phases/P7.md` marked done.

---

### Phase 6 — Tests (1 PR, can parallel Phase 4–5)

| Test file | Covers |
|-----------|--------|
| `tests/jac-cli.test.ts` | `parseJacCheckOutput`, `findJacBinary` (mock PATH) |
| `tests/bridge.test.ts` | Event type → store snapshot transitions |
| `tests/dev-mode.test.ts` | `shouldAutoApprove`, `isDestructiveBash`, plan tool filter |
| `tests/smoke.test.ts` | `runNextAgentSmoke` with mocked `Agent` (or integration with `--check`) |

Add `"test": "vitest run"` to `package.json`; wire in CI.

**Exit:** ≥ 15 tests; CI runs on PR.

---

### Phase 7 — Optional rename `pi/` → `jackal/` (defer)

Low priority; breaks `JACKAL_AGENT_DIR`, docs, and user symlinks.

| If renamed | Update |
|------------|--------|
| `pi/` → `jackal/` | `jackal.sh`, `system-prompt.ts`, `mcp-client.ts`, `subagents.ts`, `jac-workflows.ts`, `resolveJackalRoot()` |

Until then: treat `pi/` as **“Jackal package data”**, not “Pi runtime”.

---

## File disposition — `src/` (canonical runtime)

| File | Action | Notes |
|------|--------|-------|
| `src/index.ts` | **KEEP** | CLI entry + re-exports |
| `src/store.ts` | **KEEP** | Immutable snapshot store |
| `src/bridge.ts` | **KEEP** | Event → store |
| `src/ui-context.ts` | **KEEP** | Dialogs, notify |
| `src/auth-flow.ts` | **KEEP** | Login state machine |
| `src/auth-actions.ts` | **KEEP** | Auth UI actions |
| `src/completions.ts` | **KEEP** | Slash autocomplete |
| `src/cli-run.ts` | **KEEP** | Headless `jackal run` |
| `src/adapter.ts` | **SHRINK** | Wiring only (Phase 3) |
| `src/runtime/agent-session.ts` | **KEEP + extend** | Autocheck, plan hooks, slimmer fix delegate |
| `src/runtime/agent-tool.ts` | **KEEP** | Subagent tool |
| `src/runtime/auth.ts` | **KEEP** | |
| `src/runtime/session.ts` | **KEEP** | |
| `src/runtime/session-index.ts` | **KEEP** | |
| `src/runtime/mcp-client.ts` | **KEEP** | |
| `src/runtime/tools.ts` | **SHRINK** | Phase 4 tool list |
| `src/runtime/jac-cli.ts` | **KEEP** | Single Jac CLI helper |
| `src/runtime/jac-types.ts` | **KEEP** | |
| `src/runtime/jac-doctor.ts` | **KEEP** | |
| `src/runtime/jac-workflows.ts` | **KEEP** | |
| `src/runtime/jac-fix.ts` | **NEW** | Phase 5 |
| `src/runtime/dev-mode.ts` | **KEEP** | |
| `src/runtime/plan-mode.ts` | **NEW** | Phase 2 |
| `src/runtime/project-config.ts` | **KEEP** | |
| `src/runtime/tool-approval.ts` | **KEEP** | |
| `src/runtime/context-input.ts` | **KEEP** | `@file`, `!cmd` |
| `src/runtime/context-usage.ts` | **KEEP** | |
| `src/runtime/system-prompt.ts` | **KEEP** | |
| `src/runtime/custom-commands.ts` | **KEEP** | |
| `src/runtime/subagents.ts` | **KEEP** | + subagent model pins from legacy settings |
| `src/runtime/subagent-runner.ts` | **KEEP** | |
| `src/runtime/chains.ts` | **KEEP** | |
| `src/runtime/frontmatter.ts` | **KEEP** | |
| `src/runtime/checkpoints.ts` | **KEEP** | |
| `src/runtime/tasks.ts` | **KEEP** | |
| `src/runtime/task-tools.ts` | **KEEP** | |

---

## File disposition — templates / launcher

| File | Action | Notes |
|------|--------|-------|
| `templates/shell.cl.jac` | **KEEP + refactor** | Slash routing → handler imports |
| `templates/jackal_agent_facade.mjs` | **KEEP + shrink** | Session-first API |
| `templates/components/*.cl.jac` | **KEEP** | |
| `jackal.sh` | **KEEP + simplify** | Remove `--pi`; optional rename `PI_DIR` → `JACKAL_DIR` |
| `templates/.jac/tui/*` | **GENERATED** | Never hand-edit; gitignore if not already |

---

## File disposition — docs / package

| File | Action |
|------|--------|
| `docs/CONSOLIDATION_PLAN.md` | **KEEP** (this file) |
| `docs/GAME_PLAN.md` | **UPDATE** — link here; mark legacy port complete after Phase 1 |
| `docs/phases/P7.md` | **UPDATE** — point at `src/runtime/jac-*`, not `pi/extensions` |
| `AGENTS.md` | **UPDATE** — remove Pi extension architecture; `pi/` = package data |
| `package.json` `pi` manifest | **REMOVE** after extension delete |

---

## Dependency cleanup (after Phase 1)

| Package | Likely action |
|---------|---------------|
| `@earendil-works/pi-agent-core`, `@earendil-works/pi-ai` | **KEEP** — agent loop |
| `pi-subagents` | **REMOVE** if `subagent-runner.ts` is self-contained |
| `pi-lsp-extension` | **REMOVE** — was Pi-extension only |
| `pi-mcp-adapter` | **REMOVE** — replaced by `mcp-client.ts` |
| `pi-mermaid` | **REMOVE** or re-add as Ink feature later |
| `@pi-unipi/notify` | **REMOVE** unless Ink shell uses it |
| `patch-package` + `patches/@pi-unipi+notify*` | **REMOVE** with notify |

---

## Risk register

| Risk | Mitigation |
|------|------------|
| Autocheck/regression after deleting Pi hooks | Port hook logic to `agent-session.ts` in same PR as delete |
| Shell slash commands break | Update `shell.cl.jac` + facade in same PR as adapter shrink |
| Users on `--pi` | Hard error + message pointing to `./jackal.sh` |
| `/fix` still half-baked | Phase 5 exit criteria; don't claim P7 done until loop closes |
| Subagent model pins lost | Audit `pi/extensions/jackal/settings.ts` before delete |

---

## Success metrics

| Metric | Before | After |
|--------|--------|-------|
| Runtime trees | `src/` + `pi/extensions/` | `src/` only |
| `adapter.ts` LOC | ~583 | < 200 |
| `commands.ts` LOC | ~1086 | 0 (deleted) |
| Duplicate `parseJacCheckOutput` | 2 | 1 |
| Plan mode whitelists | 2 | 1 |
| LLM Jac tools (local) | ~8 overlapping MCP | 0–1 (`jac_cli` escape hatch) |
| Tests | 0 | ≥ 15 |
| Launch paths | 2 (`jackal.sh`, `--pi`) | 1 |

---

## Suggested PR sequence

```
PR1  Phase 0 — freeze legacy, CI smoke
PR2  Phase 1 — delete pi/extensions/*
PR3  Phase 2 — plan-mode.ts + session state
PR4  Phase 3a — shrink adapter + slash-handlers.ts
PR5  Phase 3b — autocheck/plan hooks in agent-session
PR6  Phase 4 — trim tools.ts to core + MCP
PR7  Phase 5 — jac-fix.ts + real /fix loop
PR8  Phase 6 — vitest suite
PR9  (optional) Phase 7 — pi/ → jackal/ rename
```

**First PR to ship:** Phase 0 + Phase 1 together if confident; otherwise Phase 0 alone.

---

## Quick reference: what nanochat would do here

> One script boots the chat. One engine generates tokens. One execution module runs code. No second registry of the same tools. No 1000-line command file. Tests on the engine.

Jackal equivalent:

> `./jackal.sh` boots Ink. `agent-session.ts` runs the loop. `jac-cli.ts` parses compiler output. MCP serves the LLM. Slash commands are thin wrappers in `slash-handlers.ts`. Everything else is delete or merge.
