# Jackal — Jac-native coding agent

## Guidelines

- Commit after each feature or bugfix

## What

A full-fledged coding agent for Jac/Jaseci development. Jackal runs as an Ink TUI with a headless TypeScript runtime — it does **not** use Pi as its shell.

## Architecture

Jac-native agent project with:
- `jackal/SYSTEM.md` — custom Jackal system prompt that emphasizes evidence-based decisions, spatial modeling, and OSP-first design
- `jackal/mcp.json` — wires up the official **Jac MCP server** (`jac mcp`), which exposes the full Jac toolchain as 19 LLM-callable tools (`validate_jac`, `check_syntax`, `run_jac`, `format_jac`, `lint_jac`, `explain_error`, `list_examples`, `get_example`, `search_docs`, `get_resource`, `get_ast`, `py_to_jac`, `jac_to_py`, `jac_to_js`, `graph_visualize`, `list_commands`, `get_command`, `execute_command`, `understand_jac_and_jaseci`) plus 52 doc resources and 9 prompts.
- `mermaid-renderer` — renders Mermaid diagrams as ASCII art in the TUI. Supports flowchart, sequence, class, ER, and state diagrams. Auto-renders mermaid blocks in chat or via a `/mermaid` command.
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

For active development, treat `src/` + `templates/` as primary and keep architecture/runtime decisions aligned with:
- `docs/FEATURES.md`
- `docs/JAC-TUI.md`
- `docs/PLAN.md`

## Project structure

```
jackal/
├── AGENTS.md                    # this file
├── README.md
├── ROADMAP.md
├── jackal.sh                    # launcher script
├── src/                         # headless agent runtime (canonical)
├── templates/                   # Ink shell (shell.cl.jac + facade)
├── pi/                          # package data (not a Pi extension runtime)
│   ├── SYSTEM.md                # Jackal system prompt
│   ├── settings.json            # model defaults, subagent overrides
│   ├── mcp.json                 # registers `jac mcp` server
│   ├── skills/                  # Jac SKILL.md files
│   ├── prompts/                 # workflow prompt templates
│   ├── .pi/agents/              # built-in subagent definitions
│   └── chains/                  # saved subagent chain workflows
├── docs/
│   └── CONSOLIDATION_PLAN.md    # runtime consolidation roadmap
└── reference/
    └── pi-lsp-extension/        # legacy reference only
```

## Development

Primary workflow:

```bash
npm run build:agent   # compile TS adapter → dist/
./jackal.sh           # compile shell.cl.jac via jac-ink and run Ink app
```

## Status and roadmap

Jackal is a Jac-native terminal agent. All active development targets the Ink shell launched by `./jackal.sh`.

Current priorities:
- Fast, reliable TUI boot (defer heavy work like MCP until after first render)
- Stabilize streaming/render behavior in the Ink shell
- Harden adapter/bridge behavior in `src/`
- Keep Jac MCP tooling as the primary validate/run/check surface
- Port remaining workflows into the Jackal runtime (`src/` + `templates/shell.cl.jac`)

The legacy Pi extension under `pi/extensions/` was **removed** (see `docs/CONSOLIDATION_PLAN.md`). Launch only via `./jackal.sh`.

## Runtime architecture notes

### Compilation pipeline (jac-ink)

The Jackal shell compiles `.cl.jac` → Ink via the **jac-ink** plugin in the separate **jac-tui** repo (`~/repos/jac-tui/jac-ink`). See `docs/JAC-TUI.md` for what belongs in jac-tui vs this repo.

**Runtime:** headless adapter in `src/`; Ink UI in `templates/shell.cl.jac` talks to the adapter through jac-ink-provided hooks (`templates/jackal_agent_facade.mjs`).

### Framework / plugin changes — human in the loop

**Do not modify jac-ink, jaclang, or jac-client yourself.** Do not write or edit shim scripts (`jac_pi_runtime_shim.mjs`, `jackal_agent_facade.mjs`, emitted runtime shims, etc.). The human maintains the jac-ink plugin and will apply toolchain fixes there.

When Jackal work requires a **framework or plugin change**, stop and **tell the human explicitly**:

- What is broken or missing (symptom + file/line if known)
- Which repo/layer owns the fix (`jac-tui/jac-ink`, `jaclang`, `jac_client`, upstream components)
- The minimal change you would recommend (design note only — do not implement it in those repos)
- Any workaround still needed in this repo until the plugin is updated

Examples that belong in jac-tui/jac-ink (describe to human, do not patch):

- Vite bypass / `ClientBundleBuilder` for Ink
- `@jac/pi` import detection, rewrite, and `_ensure_pi_import()`
- Adapter injection (`--adapter`, `JACKAL_AGENT_DIST`, etc.) instead of copying shims in `jackal.sh`
- `.cl.jac` module stem or `@jac/pi` bundling behavior (may be jaclang/jac_client upstream)

**Work in this repo only:** `src/` (adapter, store, bridge, auth), `templates/shell.cl.jac` (Ink UI), `jackal.sh` launch wiring, docs, and skills under `pi/skills/` — not jac-ink internals.

### Running

```bash
npm run build:agent   # compile TS adapter
./jackal.sh           # compile shell via jac-ink + run Ink app (interactive terminal required)
```

Non-interactive runs fail on Ink raw mode (TTY required).

Reference docs: `docs/FEATURES.md`, `docs/JAC-TUI.md`, `docs/PLAN.md`.
