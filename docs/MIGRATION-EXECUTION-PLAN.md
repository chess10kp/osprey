# Jackal: Jac Core Migration — Execution Plan

> **Superseded by the 2026-08-17 all-Jac pivot.** This bridge-oriented execution plan is retained for history only. Do not execute further phases; use [`../ROADMAP.md`](../ROADMAP.md).

**Status:** Ready to execute Phase 0  
**Last updated:** 2026-05-25  
**Source:** [JAC-CORE-MIGRATION.md](./JAC-CORE-MIGRATION.md)  

---

## Current State Summary

| Metric | Value |
|--------|-------|
| TypeScript source files | 56 |
| Total TypeScript LOC | ~13,200 |
| Largest file | `agent-session.ts` (1,000 lines) |
| Test files (adapter) | 19 (~1,975 LOC) |
| Test files (TUI) | 13 |
| npm build output | `dist/index.js` |
| Launch path | `jackal.sh` → `tsc` → `node dist/index.js` → `@jac/pi` facade → `shell.cl.jac` |
| `lib/jac/` | Does not exist yet |
| jac.toml | Has `pi-agent-core` + `pi-ai` as npm deps |

### Dependency graph (simplified)

```
index.ts
  └── core/adapter.ts (735 LOC) — wires everything
       ├── core/store.ts (392) — AgentSnapshot, immutable store
       ├── core/bridge.ts (314) — event → store mutations
       ├── core/ui-context.ts (170) — dialog/notification state
       ├── core/agent-busy.ts (14) — guard flag
       ├── core/tool-summary.ts (177) — tool output formatting
       ├── session/agent-session.ts (1000) — THE agent loop
       │    ├── agent/tools.ts (703) — all tool definitions
       │    │    ├── jac/jac-cli.ts (253) — jac CLI wrapper
       │    │    ├── jac/jac-doctor.ts (200) — doctor checks
       │    │    ├── jac/lsp-tools.ts (418) — LSP tool functions
       │    │    ├── jac/lsp-service.ts (364) — LSP service lifecycle
       │    │    ├── jac/lsp-client.ts (384) — LSP client transport
       │    │    ├── agent/task-tools.ts (235) — task CRUD tools
       │    │    ├── agent/web-tools.ts (302) — web search/fetch
       │    │    ├── agent/agent-tool.ts (80) — subagent tool factory
       │    │    └── render/mermaid-render.ts (505) — ASCII renderer
       │    ├── agent/mcp-client.ts (132) — MCP connection
       │    ├── agent/tool-approval.ts (84) — approval queue
       │    ├── agent/subagent-approval.ts (81) — subagent approval
       │    ├── agent/session-permissions.ts (388) — permission system
       │    ├── agent/dev-mode.ts (209) — mode logic
       │    ├── agent/system-prompt.ts (31) — prompt loader
       │    ├── agent/mcp-schema.ts (73) — MCP type schemas
       │    ├── session/session.ts (368) — session persistence
       │    ├── session/session-index.ts (304) — session listing
       │    ├── session/auto-compact.ts (144) — auto-compact logic
       │    ├── session/llm-compact.ts (50) — LLM compaction
       │    ├── session/outbound-queue.ts (28) — event queue
       │    ├── auth/auth.ts (183) — auth client
       │    ├── auth/auth-flow.ts (182) — auth flow state machine
       │    ├── auth/auth-actions.ts (231) — auth action handlers
       │    ├── config/project-config.ts (108) — config loading
       │    ├── workflow/checkpoints.ts (369) — checkpoint system
       │    ├── workflow/tasks.ts (162) — task persistence
       │    ├── workflow/context-input.ts (129) — context expansion
       │    ├── workflow/context-usage.ts (79) — token estimation
       │    ├── workflow/custom-commands.ts (203) — slash commands
       │    ├── workflow/file-mention-parser.ts (131) — @-mention parsing
       │    ├── workflow/skill-commands.ts (30) — skill catalog
       │    ├── orchestration/subagents.ts (282) — subagent catalog
       │    ├── orchestration/chains.ts (175) — chain catalog
       │    ├── orchestration/subagent-runner.ts (371) — subagent execution
       │    ├── orchestration/frontmatter.ts (97) — frontmatter parsing
       │    ├── project/skills.ts (517) — skill loading
       │    ├── project/project-init.ts (394) — project analysis
       │    ├── project/file-explorer.ts (94) — file listing
       │    ├── project/gitignore.ts (41) — gitignore parsing
       │    └── jac/jac-workflows.ts (177) — explain/diagram workflows
       ├── cli/run.ts (312) — headless CLI
       └── ui/completions.ts (183) — autocomplete suggestions
            └── ui/overlay-rows.ts (26) — overlay formatting
                 └── ui/approval-display.ts (232) — approval UI data
```

---

## Phase 0 — Feasibility Spike (1-3 days)

**Goal:** Answer "can Jac host the agent loop?" before committing to Phases 1-5.

### 0.1 Create target directory structure

```
lib/jac/
├── spike/
│   └── agent_spike.jac
└── (empty dirs for later phases)
```

### 0.2 Validate npm interop from Jac

Create `lib/jac/spike/agent_spike.jac` that:

1. **Imports `@earendil-works/pi-agent-core`** via Jac's npm interop
   ```jac
   # Test: can we instantiate an Agent?
   import from "@earendil-works/pi-agent-core" { Agent, AgentMessage }
   ```
2. **Creates an Agent instance** with a minimal config
3. **Runs one headless turn** — prompt → tool call → response → `agent_end`
4. **Prints the result** — confirms the full loop completes

### 0.3 Validate `jac run` entry point

- Confirm `jac run lib/jac/spike/agent_spike.jac` works
- Confirm `--check` flag can be exercised from a Jac module
- Document any `jac.toml` configuration needed for npm imports

### 0.4 Document blockers

If any of these fail, document the blocker and file upstream:
- Jac cannot import ESM npm packages
- Jac cannot instantiate classes from npm packages
- Jac cannot handle async/await patterns needed by pi-agent-core
- `jac.toml` dependency resolution doesn't support the required packages

### Gate 0 Criteria (Go/No-Go)

- [ ] `jac run` can import npm `@earendil-works/pi-agent-core` and create an `Agent` instance
- [ ] One automated turn completes (prompt → `agent_end`) from a Jac entry module
- [ ] `./jackal.sh --check` can run toolchain checks via `lib/jac/jac_cli.jac` (or documented blocker filed)
- [ ] No fundamental interop blockers that would prevent Phases 1-5

**If Gate 0 fails →** File upstream issues, defer to jaclang roadmap, do not proceed.

---

## Phase 1 — Wire Jac Toolchain Modules (3-5 days)

**Goal:** Single source of truth for Jac CLI helpers; delete TS duplicates.

### Port order (bottom-up, no internal deps):

| # | TS Source | Lines | Jac Target | Notes |
|---|-----------|-------|------------|-------|
| 1.1 | `jac/jac-types.ts` | 17 | `lib/jac/jac/types.jac` | Pure types, no deps |
| 1.2 | `jac/jac-cli.ts` | 253 | `lib/jac/jac/cli.jac` | Wraps `jac` subprocess |
| 1.3 | `jac/jac-doctor.ts` | 200 | `lib/jac/jac/doctor.jac` | Diagnostic checks |
| 1.4 | `jac/jac-workflows.ts` | 177 | `lib/jac/jac/workflows.jac` | Explain/diagram/init |
| 1.5 | `jac/lsp-client.ts` | 384 | `lib/jac/jac/lsp_client.jac` | LSP transport |
| 1.6 | `jac/lsp-service.ts` | 364 | `lib/jac/jac/lsp_service.jac` | Depends on lsp-client |
| 1.7 | `jac/lsp-tools.ts` | 418 | `lib/jac/jac/lsp_tools.jac` | Depends on lsp-service |

### Wire into runtime

During Phase 1, the TS `core/adapter.ts` still runs the show. We wire it to call the new Jac modules:

1. **Option A (preferred):** TS imports compiled Jac modules directly
2. **Option B:** TS spawns `jac run` for toolchain operations
3. **Option C:** Jac modules expose a Python API that TS calls via subprocess

The choice depends on Phase 0 spike results.

### Delete TS duplicates

After wiring and green tests:
- Delete `src/jac/jac-cli.ts`
- Delete `src/jac/jac-doctor.ts`
- Delete `src/jac/jac-types.ts`
- Delete `src/jac/jac-workflows.ts`
- Delete `src/jac/lsp-client.ts`
- Delete `src/jac/lsp-service.ts`
- Delete `src/jac/lsp-tools.ts`

### Tests

- Port `tests/adapter/jac-cli.test.ts` (71 LOC)
- Port `tests/adapter/lsp-service.test.ts` (47 LOC)
- Run full adapter test suite to confirm no regressions

### Gate 1 Criteria

- [ ] Toolchain Jac modules wired; TS duplicates in `src/jac/` deleted
- [ ] No regressions in `tests/adapter/jac-cli.test.ts` (ported or replaced)
- [ ] `./jackal.sh --check` still works end-to-end

---

## Phase 2 — Leaf Modules (5-8 days)

**Goal:** Port all pure data/logic modules with no circular deps on store or agent-session.

### Module groups (port in this order):

#### Group 2A — Config + Project (no internal deps)

| # | TS Source | Lines | Jac Target |
|---|-----------|-------|------------|
| 2A.1 | `config/project-config.ts` | 108 | `lib/jac/config/project_config.jac` |
| 2A.2 | `project/gitignore.ts` | 41 | `lib/jac/project/gitignore.jac` |
| 2A.3 | `project/file-explorer.ts` | 94 | `lib/jac/project/file_explorer.jac` |

#### Group 2B — Project skills (depends on config)

| # | TS Source | Lines | Jac Target |
|---|-----------|-------|------------|
| 2B.1 | `project/skills.ts` | 517 | `lib/jac/project/skills.jac` |
| 2B.2 | `project/project-init.ts` | 394 | `lib/jac/project/project_init.jac` |

#### Group 2C — Orchestration metadata (no internal deps)

| # | TS Source | Lines | Jac Target |
|---|-----------|-------|------------|
| 2C.1 | `orchestration/frontmatter.ts` | 97 | `lib/jac/orchestration/frontmatter.jac` |
| 2C.2 | `orchestration/subagents.ts` | 282 | `lib/jac/orchestration/subagents.jac` |
| 2C.3 | `orchestration/chains.ts` | 175 | `lib/jac/orchestration/chains.jac` |

#### Group 2D — Workflow (depends on project skills)

| # | TS Source | Lines | Jac Target |
|---|-----------|-------|------------|
| 2D.1 | `workflow/context-usage.ts` | 79 | `lib/jac/workflow/context_usage.jac` |
| 2D.2 | `workflow/context-input.ts` | 129 | `lib/jac/workflow/context_input.jac` |
| 2D.3 | `workflow/file-mention-parser.ts` | 131 | `lib/jac/workflow/file_mention_parser.jac` |
| 2D.4 | `workflow/tasks.ts` | 162 | `lib/jac/workflow/tasks.jac` |
| 2D.5 | `workflow/checkpoints.ts` | 369 | `lib/jac/workflow/checkpoints.jac` |
| 2D.6 | `workflow/custom-commands.ts` | 203 | `lib/jac/workflow/custom_commands.jac` |
| 2D.7 | `workflow/skill-commands.ts` | 30 | `lib/jac/workflow/skill_commands.jac` |

#### Group 2E — Agent helpers (no store deps)

| # | TS Source | Lines | Jac Target |
|---|-----------|-------|------------|
| 2E.1 | `agent/system-prompt.ts` | 31 | `lib/jac/agent/system_prompt.jac` |
| 2E.2 | `agent/dev-mode.ts` | 209 | `lib/jac/agent/dev_mode.jac` |
| 2E.3 | `agent/mcp-schema.ts` | 73 | `lib/jac/agent/mcp_schema.jac` |
| 2E.4 | `agent/tool-output-limit.ts` | 95 | `lib/jac/agent/tool_output_limit.jac` |
| 2E.5 | `agent/task-tools.ts` | 235 | `lib/jac/agent/task_tools.jac` |
| 2E.6 | `agent/web-tools.ts` | 302 | `lib/jac/agent/web_tools.jac` |
| 2E.7 | `agent/session-permissions.ts` | 388 | `lib/jac/agent/session_permissions.jac` |

#### Group 2F — Render + UI helpers

| # | TS Source | Lines | Jac Target |
|---|-----------|-------|------------|
| 2F.1 | `render/mermaid-render.ts` | 505 | `lib/jac/render/mermaid_render.jac` |
| 2F.2 | `ui/overlay-rows.ts` | 26 | `lib/jac/ui/overlay_rows.jac` |
| 2F.3 | `ui/approval-display.ts` | 232 | `lib/jac/ui/approval_display.jac` |
| 2F.4 | `ui/completions.ts` | 183 | `lib/jac/ui/completions.jac` |

### Tests to port in Phase 2

| Test File | LOC |
|-----------|-----|
| `tests/adapter/file-explorer-gitignore.test.ts` | (combined) |
| `tests/adapter/file-mention-parser.test.ts` | 72 |
| `tests/adapter/store.test.ts` | 128 |
| `tests/adapter/dev-mode.test.ts` | 141 |
| `tests/adapter/tool-output-limit.test.ts` | 85 |
| `tests/adapter/tool-summary.test.ts` | 67 |
| `tests/adapter/mcp-schema.test.ts` | 67 |
| `tests/adapter/web-tools.test.ts` | 63 |
| `tests/adapter/session-permissions.test.ts` | 220 |
| `tests/adapter/skills.test.ts` | 152 |
| `tests/adapter/overlay-rows.test.ts` | 66 |
| `tests/adapter/auto-compact-config.test.ts` | 48 |

### Gate 2 Criteria

- [ ] Leaf modules ported (config, tasks, checkpoints, orchestration metadata)
- [ ] Store snapshot shape documented and frozen
- [ ] All adapter tests green

---

## Phase 3 — State + Auth + Session Storage (3-5 days)

**Goal:** Move the state spine to Jac. This is the critical phase — Ink components depend on `AgentSnapshot`.

### Port order:

| # | TS Source | Lines | Jac Target | Notes |
|---|-----------|-------|------------|-------|
| 3.1 | `core/agent-busy.ts` | 14 | `lib/jac/core/agent_busy.jac` | Trivial guard flag |
| 3.2 | `core/store.ts` | 392 | `lib/jac/core/store.jac` | **AgentSnapshot shape** |
| 3.3 | `core/tool-summary.ts` | 177 | `lib/jac/core/tool_summary.jac` | Tool output formatting |
| 3.4 | `core/bridge.ts` | 314 | `lib/jac/core/bridge.jac` | Event → store mutations |
| 3.5 | `core/ui-context.ts` | 170 | `lib/jac/core/ui_context.jac` | Dialog/notification state |
| 3.6 | `auth/auth.ts` | 183 | `lib/jac/auth/auth.jac` | Auth client |
| 3.7 | `auth/auth-flow.ts` | 182 | `lib/jac/auth/auth_flow.jac` | Auth state machine |
| 3.8 | `auth/auth-actions.ts` | 231 | `lib/jac/auth/auth_actions.jac` | Auth actions |
| 3.9 | `session/session.ts` | 368 | `lib/jac/session/session.jac` | Session persistence |
| 3.10 | `session/session-index.ts` | 304 | `lib/jac/session/session_index.jac` | Session listing |
| 3.11 | `core/adapter.ts` | 735 | `lib/jac/core/adapter.jac` | Rewrite to use Jac modules |

### Critical: Freeze AgentSnapshot

Before Phase 4, the `AgentSnapshot` interface must be frozen. The Ink shell's `@jac/pi` facade reads this shape. Any changes require coordinated updates to:
- `templates/shell.cl.jac` — all `useAgentState()` consumers
- `templates/jackal_agent_facade.mjs` — the facade bridge
- `src/core/store.ts` → `lib/jac/core/store.jac` — the source of truth

### Bridge to Ink

After Phase 3, the `@jac/pi` facade must read from Jac-compiled modules. Two paths:
1. **Facade imports Jac-compiled Python** — if Jac can expose a JS API
2. **Facade spawns Jac subprocess** — simpler but higher latency
3. **In-process agent** — shell imports agent modules directly (ideal, requires jac-ink support)

### Tests to port

| Test File | LOC |
|-----------|-----|
| `tests/adapter/store.test.ts` | 128 |
| `tests/adapter/bridge.test.ts` | 310 |
| `tests/adapter/agent-busy.test.ts` | 58 |
| `tests/adapter/session-retention.test.ts` | 59 |

### Gate 3 Criteria

- [ ] `store`, `bridge`, `ui-context`, `auth-flow` running in Jac
- [ ] `@jac/pi` facade reads Jac-compiled agent (or shell imports agent directly)
- [ ] Agent-session public API stable (no pending redesign of approval, compaction, or subagent wiring)
- [ ] Ink TUI renders correctly with Jac backend (smoke test)

---

## Phase 4 — Agent Core (5-10 days)

**Goal:** Port the entire agent loop — tools, approvals, subagents, compaction, MCP, LSP, agent-session.

This is the longest phase. Port only after Gate 3 (API stable).

### Port order:

| # | TS Source | Lines | Jac Target | Notes |
|---|-----------|-------|------------|-------|
| 4.1 | `agent/tool-approval.ts` | 84 | `lib/jac/agent/tool_approval.jac` | Approval queue |
| 4.2 | `agent/subagent-approval.ts` | 81 | `lib/jac/agent/subagent_approval.jac` | Subagent approval |
| 4.3 | `agent/agent-tool.ts` | 80 | `lib/jac/agent/agent_tool.jac` | Subagent tool factory |
| 4.4 | `agent/mcp-client.ts` | 132 | `lib/jac/agent/mcp_client.jac` | May need thin Node bridge |
| 4.5 | `agent/tools.ts` | 703 | `lib/jac/agent/tools.jac` | All tool definitions |
| 4.6 | `orchestration/subagent-runner.ts` | 371 | `lib/jac/orchestration/subagent_runner.jac` | Subagent execution |
| 4.7 | `session/auto-compact.ts` | 144 | `lib/jac/session/auto_compact.jac` | Auto-compact logic |
| 4.8 | `session/llm-compact.ts` | 50 | `lib/jac/session/llm_compact.jac` | LLM compaction |
| 4.9 | `session/outbound-queue.ts` | 28 | `lib/jac/session/outbound_queue.jac` | Event queue |
| 4.10 | `session/agent-session.ts` | 1000 | `lib/jac/session/agent_session.jac` | **THE BIG ONE** |
| 4.11 | `cli/run.ts` | 312 | `lib/jac/cli/run.jac` | Headless CLI |
| 4.12 | `src/index.ts` | 243 | `lib/jac/main.jac` | New entry point |

### Key decisions during Phase 4:

1. **How to handle `pi-agent-core` Agent class?**
   - Option A: Import from npm via Jac interop (validated in Phase 0)
   - Option B: Keep thin TS wrapper, call from Jac
   - Option C: Replace with byLLM agent loop (separate decision — JAC-AI-PARITY.md)

2. **How to handle Node.js APIs?**
   - `child_process.spawn` → Jac subprocess or Python `subprocess`
   - `fs.readFile/writeFile` → Jac file I/O or Python `pathlib`
   - `net` socket for LSP → May need thin Node bridge

### Tests to port

| Test File | LOC |
|-----------|-----|
| `tests/adapter/subagent-approval.test.ts` | 48 |
| `tests/adapter/context-input.test.ts` | (check) |
| `tests/adapter/cli-harness.test.ts` | 58 |
| `tests/adapter/smoke.test.ts` | 80 |
| Full `--check` smoke test | — |

### Gate 4 Criteria

- [ ] Full interactive TUI + `jackal run` + `--check` on Jac-only path
- [ ] Adapter vitest suite migrated or replaced
- [ ] `npm run build:agent` / `dist/` removed from `jackal.sh`
- [ ] All adapter tests green

---

## Phase 5 — Decommission TypeScript (2-3 days)

**Goal:** Remove `src/`, `dist/`, `tsc` from launch path.

### Tasks:

1. **Rewrite `jackal.sh`:**
   - `jac run lib/jac/main.jac` for headless
   - `jac tui templates/shell.cl.jac` for TUI
   - Remove `npm run build:agent`, `dist/index.js` references

2. **Create `lib/jac/main.jac`:**
   - Replaces `core/adapter.ts` + `src/index.ts`
   - CLI arg parsing for `--check`, `run`, `--mode`
   - Entry walker that boots the agent

3. **Delete TypeScript artifacts:**
   - `rm -rf src/ dist/`
   - Remove `tsconfig.json`
   - Remove `vitest.config.ts` (replaced by Jac tests)
   - Remove `npm run build:agent` from `package.json`
   - Remove `@earendil-works/pi-agent-core` from devDeps (moved to `jac.toml`)

4. **Update documentation:**
   - PLAN.md — new architecture diagram
   - FEATURES.md — no changes needed
   - AGENTS.md — new development workflow
   - ROADMAP.md — mark migration complete
   - README.md — update build instructions

5. **Final verification:**
   - `./jackal.sh` launches TUI
   - `./jackal.sh --check` runs smoke check
   - `./jackal.sh run "prompt"` runs headless
   - All tests green

---

## Target Layout

```
jackal/
├── lib/jac/                          # agent core (server-side .jac)
│   ├── main.jac                      # CLI entry: --check, run, headless
│   ├── spike/
│   │   └── agent_spike.jac           # Phase 0 feasibility (kept as reference)
│   ├── core/
│   │   ├── store.jac                 # AgentSnapshot, immutable store
│   │   ├── bridge.jac                # event → store mutations
│   │   ├── ui_context.jac            # dialog/notification state
│   │   ├── agent_busy.jac            # guard flag
│   │   ├── adapter.jac               # wires everything
│   │   └── tool_summary.jac          # tool output formatting
│   ├── session/
│   │   ├── agent_session.jac         # THE agent loop
│   │   ├── session.jac               # session persistence
│   │   ├── session_index.jac         # session listing
│   │   ├── auto_compact.jac          # auto-compact logic
│   │   ├── llm_compact.jac           # LLM compaction
│   │   └── outbound_queue.jac        # event queue
│   ├── agent/
│   │   ├── tools.jac                 # all tool definitions
│   │   ├── tool_approval.jac         # approval queue
│   │   ├── subagent_approval.jac     # subagent approval
│   │   ├── agent_tool.jac            # subagent tool factory
│   │   ├── session_permissions.jac   # permission system
│   │   ├── dev_mode.jac              # mode logic
│   │   ├── system_prompt.jac         # prompt loader
│   │   ├── mcp_client.jac            # MCP connection
│   │   ├── mcp_schema.jac            # MCP type schemas
│   │   ├── task_tools.jac            # task CRUD tools
│   │   ├── web_tools.jac             # web search/fetch
│   │   └── tool_output_limit.jac     # output truncation
│   ├── auth/
│   │   ├── auth.jac                  # auth client
│   │   ├── auth_flow.jac             # auth state machine
│   │   └── auth_actions.jac          # auth action handlers
│   ├── workflow/
│   │   ├── checkpoints.jac           # checkpoint system
│   │   ├── tasks.jac                 # task persistence
│   │   ├── context_input.jac         # context expansion
│   │   ├── context_usage.jac         # token estimation
│   │   ├── custom_commands.jac       # slash commands
│   │   ├── file_mention_parser.jac   # @-mention parsing
│   │   └── skill_commands.jac        # skill catalog
│   ├── orchestration/
│   │   ├── subagents.jac             # subagent catalog
│   │   ├── chains.jac                # chain catalog
│   │   ├── subagent_runner.jac       # subagent execution
│   │   └── frontmatter.jac           # frontmatter parsing
│   ├── project/
│   │   ├── project_config.jac        # config loading
│   │   ├── project_init.jac          # project analysis
│   │   ├── skills.jac                # skill loading
│   │   ├── file_explorer.jac         # file listing
│   │   └── gitignore.jac             # gitignore parsing
│   ├── jac/
│   │   ├── cli.jac                   # jac CLI wrapper
│   │   ├── doctor.jac                # diagnostic checks
│   │   ├── types.jac                 # Jac types
│   │   ├── workflows.jac             # explain/diagram
│   │   ├── lsp_client.jac            # LSP transport
│   │   ├── lsp_service.jac           # LSP service lifecycle
│   │   └── lsp_tools.jac             # LSP tool functions
│   ├── render/
│   │   └── mermaid_render.jac        # ASCII renderer
│   ├── ui/
│   │   ├── overlay_rows.jac          # overlay formatting
│   │   ├── approval_display.jac      # approval UI data
│   │   └── completions.jac           # autocomplete
│   └── cli/
│       └── run.jac                   # headless CLI
├── templates/
│   └── shell.cl.jac                  # Ink UI (unchanged)
├── jac.toml                          # npm: pi-agent-core, pi-ai, ink, react
├── jackal.sh                         # jac run / jac tui (no tsc)
└── pi/                               # package data: skills, SYSTEM.md, mcp.json
```

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Jac cannot import ESM npm packages | Medium | **Critical** — blocks entire migration | Phase 0 spike validates before commitment |
| `pi-agent-core` Agent class requires Node.js APIs | High | High — may need thin bridge | Keep bridge module; port logic to Jac |
| Dual maintenance during migration | Medium | Medium — slows velocity | Strict delete-on-wire rule; no new features in both |
| Ink regression from store shape change | Low | High — TUI breaks | Freeze `AgentSnapshot` in Phase 3; snapshot tests |
| Migration stalls mid-flight | Medium | High — worst of both worlds | Phase gates; TS remains launch path until Phase 5 |
| LSP/MCP transport requires Node.js | High | Medium | Thin bridge modules for I/O; logic in Jac |

---

## Effort Estimates

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Phase 0: Spike | 1-3 days | 1-3 days |
| Phase 1: Toolchain | 3-5 days | 4-8 days |
| Phase 2: Leaf modules | 5-8 days | 9-16 days |
| Phase 3: State + auth | 3-5 days | 12-21 days |
| Phase 4: Agent core | 5-10 days | 17-31 days |
| Phase 5: Decommission | 2-3 days | 19-34 days |

**Total estimated: 3-7 weeks** (assuming one developer, full-time)

---

## Rules During Migration

1. **Delete-on-wire:** When a Jac module is wired into the runtime, delete the TS equivalent immediately. Never maintain both.
2. **No new features in TS:** Once migration starts, new agent-core features go in Jac only.
3. **TS remains launch path until Phase 5:** The production path stays TypeScript until every module is ported and tested.
4. **Every ported module ships with parity tests:** Before deleting TS, confirm the Jac version passes the same tests.
5. **Phase gates are hard:** Do not skip phases. Each gate must be met before proceeding.
