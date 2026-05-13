# Jackal

## Jackal Coding Agent

A Pi-powered, terminal-native Jac coding agent that gives Jac developers the agentic workflow with better keyboard ergonomics, multimodal context, CLI/toolchain awareness, and Jac-specific project intelligence.

Jackal features a **custom system prompt** that emphasizes:
- **Evidence-based decisions** — verify with `jac check`, tests, and runtime traces before architectural choices
- **Spatial modeling** — prefer nodes, edges, walkers, abilities, and traversal semantics
- **Explicit traversal** — keep walker behavior explicit, avoid hidden mutations
- **Correctness first** — do not invent syntax, undocumented APIs, or nonexistent framework behavior

### v0.1 — The Bare Loop

The smallest thing that works end to end:

- Pi session with `candidate.txt` (curl -LO https://github.com/jaseci-labs/jaseci-llmdocs/releases/latest/download/candidate.txt) injected as project context
- Single custom tool: `jac_compile` that shells out to `jac check`
- Hardcoded silent retry mode, capped at 3
- Returns final code or last attempt + errors on total failure
- No example library, no config, no mode switching

---

### v0.2 — Conversation State

- Track "current working file" across turns
- Modifications update the working file rather than regenerating from scratch
- Compile on every generation turn automatically
- Session saves working file alongside pi's normal session history

---

### v0.3 — Verbose/Silent Mode

- `verbose_retries` config flag
- `/set verbose-retries on|off` command in session
- Verbose mode surfaces each attempt and compiler output as distinct messages, with a brief model explanation of what went wrong
- Silent mode surfaces final result only, but always exposes failure state on 3-attempt exhaustion

---

### v0.4 — Model Selection

- Config for model choice surfaced as a first-class option
- Sensible default (Claude Sonnet or equivalent)
- `/set model <name>` command
- Resolves the core gap vs. jac-coder

---

### v0.5 — Example Library

- Small curated set of `.jac` examples organized by category
- Keyword-based retrieval to inject relevant examples at generation time
- Categories: basic types/functions, node/edge, walker/OSP, `by llm()`, access modifiers

---

### v0.6 — OSP Support

**Status: implemented**

- Dedicated handling for walker/node/edge generation tasks
- Richer few-shot examples for traversal patterns
- Detect OSP intent from user prompt and inject OSP-specific context

### v0.7 — Plan Mode

**Status: implemented**

- `/plan` — toggle plan mode (read-only exploration, then execute with full access)
- `plan` flag — start in plan mode via `--plan`
- Plan mode restricts Jac MCP tools to read-only operations
- Agent creates numbered plan under `Plan:` header
- Execution mode restores full Jac tool access
- Progress tracking with `[DONE:n]` markers
- TUI widget shows completion status
- Session persistence

---

## Features

### Plan Mode (`/plan`)

Read-only exploration mode for safe Jac code analysis:

- **Plan Mode (Read-Only)**: Restricts Jac MCP tools to read-only operations (`validate_jac`, `check_syntax`, `explain_error`, `search_docs`, `get_resource`, `list_examples`, `get_example`, `get_ast`)
- **Create a Plan**: Agent creates a numbered plan under a `Plan:` header without making changes
- **Execution Mode**: Full Jac tool access restored, agent executes steps in order
- **Progress Tracking**: `[DONE:n]` markers track completion, TUI widget shows progress
- **Session Persistence**: Plan state survives session resume

Usage:
```bash
/plan          # Toggle plan mode
--plan         # Start in plan mode
```

When in plan mode, ask the agent to analyze your Jac codebase and create a plan. The agent will output:
```
Plan:
1. Analyze the walker structure
2. Identify missing node types
3. Check type annotations
...
```

Then choose "Execute the plan" to switch to execution mode with full tool access.

### App Scaffolding (`/create`)

Scaffold a Jac app from a plain-language description:

```bash
/create Build a CRM-style app with Company and Contact nodes, relationship edges, and walkers for search + follow-up scheduling
```

Preset mode (with autocomplete): type `/create ` then press Tab to pick a preset.

```bash
/create api: Build a ticketing backend with Ticket and User nodes
/create auth-app: Build login/session scaffolding for a portal
/create agent-graph: Build a multi-agent delegation topology
/create workflow-engine: Build a stage-based workflow runner
```

The command queues a guided workflow for the agent to:
1. Look up Jac docs and examples (`list_examples`, `get_example`, `search_docs`, `get_resource`)
2. Design topology (nodes/edges/walkers/abilities)
3. Scaffold files (entry file + supporting modules)
4. Verify with `validate_jac`, `run_jac`, and `lint_jac`
5. Summarize how to run and extend the scaffold

---

## Subagents (`pi-subagents`)

Jackal loads **[pi-subagents](https://github.com/nicobailon/pi-subagents)** as a Pi package (see `jackal/settings.json` → `packages`). The parent session can delegate work to **child agents** with the `subagent` tool, slash commands such as `/run` and `/parallel`, or plain-language requests (“Use `scout` to map the auth flow…”).

### Builtin agents

| Agent | Role |
|--------|------|
| **scout** | Fast local recon: relevant files, entry points, data flow, risks, and where another agent should start. |
| **researcher** | Web and docs research with sources: specs, official docs, benchmarks, and a short research brief. |
| **planner** | Read the codebase and produce a concrete implementation plan; intended to plan, not ship edits. |
| **worker** | Implementation: edits files, validates, and escalates instead of guessing on unapproved decisions. |
| **reviewer** | Code review (and small fixes): checks work against the task/plan, tests, edge cases, and simplicity. |
| **context-builder** | Stronger pre-planning pass: gathers code context and can write handoff artifacts (e.g. context / meta-prompt files). |
| **oracle** | Second opinion before acting: challenges assumptions, catches drift, recommends next steps **without** editing as the default. |
| **delegate** | Lightweight general child that behaves close to the parent session (minimal preset framing). |

**Rule of thumb:** `scout` before you understand the code, `researcher` before you trust external facts, `planner` before a large change, `worker` to implement, `reviewer` to verify, `oracle` when the decision itself is risky.

Defaults and pins for these roles live under `subagents.agentOverrides` in `jackal/settings.json`. To change a role’s model from inside Jackal, use **`/subagent-model`** (lists pins, sets `provider/model-id`, or opens a model picker). Per-run overrides still work via pi-subagents (e.g. `/run reviewer[model=…] "…"`).

For slash syntax, chains, saved workflows, and diagnostics, see the [pi-subagents README](https://github.com/nicobailon/pi-subagents/blob/main/README.md).

---

### Quick Reference

See `QUICK_REFERENCE.md` for a condensed guide to all slash commands, flags, and common workflows.

---

## Deferred

- RAG over spec (revisit if context budget becomes a real problem)
- Multi-file project generation
- Fine-tuning

---
