# Jackal — Jac-native coding agent

## Guidelines

- Commit after each feature or bugfix

## What

A full-fledged coding agent written in Jac for Jac/Jaseci development. Jackal now runs through `agent-next` and does **not** depend on Pi as its runtime shell.

## Architecture

Jac-native agent project with:
- `jackal/SYSTEM.md` — custom Jackal system prompt that emphasizes evidence-based decisions, spatial modeling, and OSP-first design
- `jackal/mcp.json` — wires up the official **Jac MCP server** (`jac mcp`), which exposes the full Jac toolchain as 19 LLM-callable tools (`validate_jac`, `check_syntax`, `run_jac`, `format_jac`, `lint_jac`, `explain_error`, `list_examples`, `get_example`, `search_docs`, `get_resource`, `get_ast`, `py_to_jac`, `jac_to_py`, `jac_to_js`, `graph_visualize`, `list_commands`, `get_command`, `execute_command`, `understand_jac_and_jaseci`) plus 52 doc resources and 9 prompts.
- `mermaid-renderer` — renders Mermaid diagrams as ASCII art in the TUI. Supports flowchart, sequence, class, ER, and state diagrams. Auto-renders mermaid blocks in chat or via a `/mermaid` command.
- `extensions/jackal-toolchain.ts` — registers Jackal-specific slash commands (`/jac-doctor`, `/jac-check`, `/fix`, `/jac-verbose`, `/osp`, `/create`, `/refactor`, `/plan`, `/subagent-model`, `/commit`) and an auto-check hook that re-validates a `.jac` file after every write/edit. **Does not** register its own jac_* tools — defers to the Jac MCP for all validation, transpilation, examples, etc.
- **`.jackal` project config** — per-project JSON file that controls Jackal behavior. Read at session_start, walks up from CWD to find it. Keys: `autocheck`, `autoformat`, `verbose`, `plan`, `maxFixAttempts`, `mermaid`, `notify`, `subagents`.
- `subagents/` and `chains/` — local subagent workflows and saved chain files. Provides support for built-in agent roles (scout, planner, worker, reviewer, oracle, researcher), chain/parallel execution patterns, and model/workflow overrides via project settings.
- `subagents/agents/` — Jac-specific subagent definitions. Each is a `.md` file with YAML frontmatter (`name`, `description`, `model`, `tools`) and a system prompt body:
  - `scout` — Fast Jac codebase recon (Haiku, cheap/fast)
  - `architect` — OSP graph design and planning (Sonnet, reasoning)
  - `implementer` — Code implementation with full edit capabilities (Sonnet)

- `chains/` — Saved `.chain.md` workflow files for subagent workflows:
  - `pipeline` — scout → planner → worker (full pipeline)
- `patches/` — `patch-package` diffs applied on `npm install` via `postinstall` script:
  - `@unipi+notify+2.0.1.patch` — brands notifications as "Jackal".
  - `scout-and-design` — scout → planner (investigate + design)

- `skills/` — Agent Skills (SKILL.md files) the LLM reads on-demand for Jac-specific workflows.
- `prompts/` — reusable prompt templates

## Allowed Tools

The canonical set of tools Jackal may use, organized by tier.

### Tier 1 — Core edit-validate-run loop (constant use)

| Tool | Purpose |
|------|---------|
| `read` | Read file contents (text or images) — understand before touching |
| `write` | Create or overwrite files |
| `edit` | Targeted text replacement in existing files |
| `bash` | Run shell commands (`jac` CLI, `git`, `find`, etc.) |
| `jac_validate_jac` | Full type-check validation of Jac code — primary correctness gate |
| `jac_check_syntax` | Parse-only syntax check (faster, no type checking) |
| `jac_run_jac` | Execute Jac code and return stdout/stderr — runtime verification |

### Tier 2 — Orientation & lookup (frequent use)

| Tool | Purpose |
|------|---------|
| `jac_search_docs` | Look up Jac syntax, APIs, and patterns by keyword |
| `code_overview` | Summarize project structure (directory tree + top-level symbols) |
| `ast_search` | Find code matching a structural pattern (walkers, nodes, etc.) |
| `lsp_diagnostics` | Get compilation errors/warnings from LSP |
| `lsp_hover` | Get type info and docs for a symbol |
| `lsp_definition` | Go to definition of a symbol |
| `lsp_references` | Find all references to a symbol |
| `lsp_completions` | Get completion suggestions at a position |

### Tier 3 — Transformation & visualization (situational)

| Tool | Purpose |
|------|---------|
| `code_rewrite` | Batch structural code transformations via AST matching |
| `lsp_rename` | Rename a symbol across the project |
| `lsp_code_actions` | Get available quick fixes / refactorings |
| `lsp_symbols` | List symbols in a file or search workspace |
| `jac_graph_visualize` | Visualize Jac graph output as DOT or JSON |
| `jac_get_ast` | Parse Jac code and return AST (tree or JSON) |

### Tier 4 — MCP gateway & orchestration

| Tool | Purpose |
|------|---------|
| `mcp` | Route to Jac MCP server (85 tools: format, lint, transpile, examples, etc.) or browsermcp |
| `subagent` | Delegate to subagents: single, chain, parallel, async execution |

### Skills (loaded on demand)

30 skills covering Jac language patterns, OSP, auth, fullstack, components, scaffolding, refactoring, diagnosis. Read via `read` tool when task matches description.

## Reference implementation

`reference/pi-lsp-extension/` remains a **legacy reference** for older Pi-extension patterns (kept for historical context).

For active development, treat `agent-next/` as primary and keep architecture/runtime decisions aligned with:
- `agent-next/docs/FEATURES.md`
- `agent-next/docs/JAC-TUI.md`
- `agent-next/docs/PLAN.md`

## Project structure

```
jackal/
├── AGENTS.md                    # this file
├── README.md
├── ROADMAP.md
├── jackal.sh                    # launcher script for agent-next shell
├── jackal/
│   ├── SYSTEM.md                # Jackal system prompt
│   ├── settings.json            # Jackal runtime/settings config
│   └── mcp.json                 # registers `jac mcp` server
├── package.json                 # npm package with project metadata and dependencies
├── extensions/
│   ├── jackal-toolchain.ts      # entry point — flags, shared context
│   └── jackal/
│       ├── check.ts             # local jac check helpers
│       ├── commands.ts          # slash command registrations
│       ├── config.ts            # .jackal project config loader
│       ├── hooks.ts             # event handler registrations
│       ├── plan-mode.ts         # plan mode constants & step tracking
│       ├── settings.ts          # settings I/O & subagent model pins
│       └── types.ts             # shared interfaces & state
├── subagents/
│   └── agents/                  # Jac-specific subagent definitions
│       ├── scout.md         # fast recon (Haiku)
│       ├── architect.md     # OSP design (Sonnet)
│       ├── implementer.md   # implementation (Sonnet)

├── chains/                      # saved subagent workflows
│   ├── pipeline.chain.md        # scout → planner → worker
│   └── scout-and-design.chain.md # scout → planner
├── patches/                    # patch-package diffs (applied on npm install)
│   └── @pi-unipi+notify+2.0.1.patch  # brands notifications as "Jackal"
├── skills/
│   ├── fix-skill/
│   ├── osp-skill/
│   ├── project-skill/
│   ├── jackal-auth/
│   └── refactor-skill/
├── prompts/
│   └── explain.md           # explain template
└── reference/
    └── pi-lsp-extension/        # reference implementation
```

## Development

Primary workflow is the Jac-native `agent-next` shell:

```bash
npm run build:agent   # compile TS adapter
./jackal.sh           # compile .cl.jac via jac-ink and run Ink app
```

Classic Pi-based flow is now legacy and should only be used for compatibility checks (`./jackal.sh --pi`).

## Status and roadmap

Jackal has transitioned from the old Pi-extension model to a Jac-native `agent-next` runtime.

Current priorities:
- Stabilize streaming/render behavior in the Ink shell
- Harden adapter/bridge behavior in `agent-next/src/`
- Keep Jac MCP tooling as the primary validate/run/check surface
- Maintain compatibility path (`./jackal.sh --pi`) only for regression checks

Historical Pi-era roadmap notes are now considered legacy context.
## Legacy Pi extension testing (compat only)

```bash
# Optional compatibility path only
./jackal.sh --pi
```

## agent-next migration notes

### Compilation pipeline (jac-ink)

The agent-next shell compiles `.cl.jac` → Ink via the **jac-ink** plugin in the separate **jac-tui** repo (`~/repos/jac-tui/jac-ink`). See `agent-next/docs/JAC-TUI.md` for what belongs in jac-tui vs this repo.

**Runtime:** agent-next runtime (node adapter + AI backend). Headless adapter in `agent-next/src/`; Ink UI in `agent-next/templates/shell.cl.jac` talks to the adapter through jac-ink-provided hooks.

### Framework / plugin changes — human in the loop

**Do not modify jac-ink, jaclang, or jac-client yourself.** Do not write or edit shim scripts (`jac_pi_runtime_shim.mjs`, `jackal_agent_facade.mjs`, emitted runtime shims, etc.). The human maintains the jac-ink plugin and will apply toolchain fixes there.

When agent-next work requires a **framework or plugin change**, stop and **tell the human explicitly**:

- What is broken or missing (symptom + file/line if known)
- Which repo/layer owns the fix (`jac-tui/jac-ink`, `jaclang`, `jac_client`, upstream components)
- The minimal change you would recommend (design note only — do not implement it in those repos)
- Any workaround still needed in this repo until the plugin is updated

Examples that belong in jac-tui/jac-ink (describe to human, do not patch):

- Vite bypass / `ClientBundleBuilder` for Ink
- `@jac/pi` import detection, rewrite, and `_ensure_pi_import()`
- Adapter injection (`--adapter`, `JACKAL_AGENT_DIST`, etc.) instead of copying shims in `jackal.sh`
- `.cl.jac` module stem or `@jac/pi` bundling behavior (may be jaclang/jac_client upstream)

**Work in this repo only:** `agent-next/src/` (adapter, store, bridge, auth), `agent-next/templates/shell.cl.jac` (Ink UI), `jackal.sh` launch wiring, docs, and Jackal extension/skills — not jac-ink internals.

### Running

```bash
npm run build:agent   # compile TS adapter
./jackal.sh           # compile shell via jac-ink + run Ink app (interactive terminal required)
```

Or `./jackal.sh --pi` for the classic Pi TUI path. Non-interactive runs fail on Ink raw mode.

Reference docs: `agent-next/docs/FEATURES.md`, `agent-next/docs/JAC-TUI.md`, `agent-next/docs/PLAN.md`.
