# Jackal — Pi-powered Jac coding agent

## Guidelines

- Commit after each feature or bugfix

## What

A Pi package that turns Pi into a specialized coding agent for Jac/Jaseci development. Installs as a local Pi package — does not touch `~/.pi/` global config.

## Architecture

Pi package with:
- `jackal/SYSTEM.md` — custom Jackal system prompt that emphasizes evidence-based decisions, spatial modeling, and OSP-first design
- `jackal/mcp.json` — wires up the official **Jac MCP server** (`jac mcp`), which exposes the full Jac toolchain as 19 LLM-callable tools (`validate_jac`, `check_syntax`, `run_jac`, `format_jac`, `lint_jac`, `explain_error`, `list_examples`, `get_example`, `search_docs`, `get_resource`, `get_ast`, `py_to_jac`, `jac_to_py`, `jac_to_js`, `graph_visualize`, `list_commands`, `get_command`, `execute_command`, `understand_jac_and_jaseci`) plus 52 doc resources and 9 prompts.
- `pi-mermaid` — renders Mermaid diagrams as ASCII art in the TUI. Supports flowchart, sequence, class, ER, and state diagrams. Auto-renders mermaid blocks in chat or via `/pi-mermaid` command.
- `extensions/jackal-toolchain.ts` — registers Jackal-specific slash commands (`/jac-doctor`, `/jac-check`, `/fix`, `/jac-verbose`, `/osp`, `/create`, `/refactor`, `/plan`, `/subagent-model`, `/commit`) and an auto-check hook that re-validates a `.jac` file after every write/edit. **Does not** register its own jac_* tools — defers to the Jac MCP for all validation, transpilation, examples, etc.
- **`.jackal` project config** — per-project JSON file that controls Jackal behavior. Read at session_start, walks up from CWD to find it. Keys: `autocheck`, `verbose`, `plan`, `maxFixAttempts`, `mermaid`, `notify`, `subagents`.
- [pi-subagents](https://pi.dev/packages/pi-subagents) — installed as an npm package (`npm:pi-subagents`). Provides the `subagent` tool, chain/parallel/background execution, built-in agents (scout, planner, worker, reviewer, oracle, researcher), saved `.chain.md` workflows, and model overrides via settings. No hand-rolled subagent code.
- `.pi/agents/` — Jac-specific subagent definitions that extend pi-subagents' builtins. Each is a `.md` file with YAML frontmatter (`name`, `description`, `model`, `tools`) and a system prompt body:
  - `scout` — Fast Jac codebase recon (Haiku, cheap/fast)
  - `architect` — OSP graph design and planning (Sonnet, reasoning)
  - `implementer` — Code implementation with full edit capabilities (Sonnet)

- `chains/` — Saved `.chain.md` workflow files for pi-subagents:
  - `pipeline` — scout → planner → worker (full pipeline)
- `patches/` — `patch-package` diffs applied on `npm install` via `postinstall` script:
  - `@pi-unipi+notify+2.0.1.patch` — brands notifications as "Jackal" instead of "Pi"
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

`reference/pi-lsp-extension/` — cloned from https://github.com/samfoy/pi-lsp-extension

This is the **primary reference** for the extension pattern. It:
- Registers multiple LLM-callable tools via `pi.registerTool()` with TypeBox schemas
- Registers slash commands via `pi.registerCommand()`
- Uses `pi.on("session_start", ...)` for initialization
- Uses `pi.on("tool_result", ...)` for post-execution hooks
- Uses `pi.on("session_shutdown", ...)` for cleanup
- Organizes tool implementations in `src/tools/` as factory functions

Key API patterns to follow:
- `import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";`
- `import { Type } from "typebox";` for parameter schemas
- Default export: `export default function (pi: ExtensionAPI) { ... }`
- Tool `execute` signature: `(toolCallId, params, signal, onUpdate, ctx) => Promise<AgentToolResult>`

## Project structure

```
jackal/
├── AGENTS.md                    # this file
├── README.md
├── ROADMAP.md
├── jackal.sh                    # launcher script (isolated Pi env)
├── jackal/
│   ├── SYSTEM.md                # Jackal system prompt
│   ├── settings.json            # isolated Pi settings (model, packages, subagent overrides)
│   └── mcp.json                 # registers `jac mcp` server
├── package.json                 # npm package with pi manifest + pi-subagents dep
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
├── .pi/
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

Jackal uses `PI_CODING_AGENT_DIR` to point to an isolated config directory (`jackal/`) so global Pi packages never load. The launcher script wraps this:

```bash
# Launch from repo root (any cwd, no global packages)
cd /some/project
/path/to/jackal/jackal.sh

# Or install as a symlink in PATH
ln -s /path/to/jackal/jackal.sh ~/.local/bin/jackal
jackal
```

### Manual flags (without launcher)

```bash
PI_CODING_AGENT_DIR=./jackal pi --no-extensions \
  -e ./extensions/jackal-toolchain.ts \
  --skill ./skills \
  --prompt-template ./prompts
```

### Project-local install (shares .pi/, still picks up packages)

```bash
pi install -l .
```

## Implementation plan

### v0.1 — The Bare Loop (current)

**Status: scaffold complete, core stubs written**

What we have:
- Pi package with manifest
- Custom `SYSTEM.md` — defines Jackal's philosophy: evidence-based decisions, spatial modeling, correctness first
- Jac MCP server provides all toolchain tools (no local jac_check/jac_run stubs)
- `/jac-doctor` — detects Jac binary, version, MCP availability, .jac files
- `/jac-check` — runs `jac check`, displays diagnostics in TUI
- `/fix` — runs check + asks agent to fix errors via Jac MCP (3-attempt cap)
- `/create` — thin TUI wrapper around `jac create`: lists available jacpack templates, picks one, runs the CLI
- `fix-skill` — SKILL.md for iterative error fixing
- `jac-project-skill` — SKILL.md for project detection
- `explain` — prompt template
- `reference/pi-lsp-extension/` — cloned reference

**Next:**
1. Implement `/fix` — the core check/fix/verify loop (capped at 3 retries, shows diff, re-runs `jac check`)
2. Write `fix-skill` — SKILL.md that guides the agent through the fix workflow
3. Test `/create` with `jac create` templates
4. Test against real `.jac` files

### v0.2 — Conversation State

Planned:
- Track "current working file" across turns via `pi.appendEntry()`
- Modifications update working file rather than regenerating from scratch
- Run `jac check` automatically after every write/edit
- Session saves working file alongside Pi's session history

### v0.3 — Verbose/Silent Mode

Planned:
- Config flag for verbose retries (`pi.registerFlag`)
- `/set verbose-retries on|off` command
- Verbose: surface each attempt + compiler output as distinct messages
- Silent: final result only, always exposes failure on exhaustion

### v0.4 — Model Selection

Planned:
- Config for model choice as first-class option
- `/set model <name>` command
- Sensible default

### v0.5 — Example Library

Planned:
- Curated `.jac` examples organized by category
- Keyword-based retrieval to inject relevant examples at generation time
- Categories: basic types/functions, node/edge, walker/OSP, `by llm()`, access modifiers

### v0.6 — OSP Support

Planned:
- Dedicated handling for walker/node/edge generation tasks
- Richer few-shot examples for traversal patterns
- Detect OSP intent from user prompt

### v0.7 — Plan Mode

**Status: implemented**

What we have:
- `/plan` — toggle plan mode (read-only exploration, then execute with full access)
- `plan` flag — start in plan mode via `--plan`
- Plan mode restricts Jac MCP tools to read-only operations
- Agent creates numbered plan under `Plan:` header
- Execution mode restores full Jac tool access
- Progress tracking with `[DONE:n]` markers
- TUI widget shows completion status
- Session persistence via `pi.appendEntry()`
- `/jac-doctor` shows plan mode status

Features:
- Plan mode: `validate_jac`, `check_syntax`, `explain_error`, `search_docs`, `get_resource`, `list_examples`, `get_example`, `get_ast`
- Execution mode: all Jac MCP tools + read/write/edit/bash
- Agent creates numbered plan under `Plan:` header and execution support

## Development

```bash
# Test extension in isolation (no global config touched)
pi --no-extensions -e ./extensions/jac-toolchain.ts

# Test with skills
pi --no-extensions -e ./extensions/jac-toolchain.ts --skill ./skills

# Install as project-local package (writes .pi/, not ~/.pi/)
pi install -l .
```
