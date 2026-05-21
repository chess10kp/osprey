# Jackal Quick Reference

## What is Jackal?

Jackal is a Pi-powered Jac coding agent with:
- Custom system prompt emphasizing evidence-based decisions and spatial modeling
- Full Jac MCP toolchain integration
- Plan mode for read-only exploration
- Auto-fix for compiler errors
- OSP-focused code generation

## Slash Commands

| Command | Description |
|---------|-------------|
| `/jac-doctor` | Check environment, version, MCP status, .jac files |
| `/jac-check [file]` | Run `jac check` and display diagnostics |
| `/fix [file] [description]` | Fix compiler errors (3-attempt cap). With a description, follows `diagnosis-skill` first. |
| `/osp <desc>` | Generate OSP code (nodes, edges, walkers) |
| `/create [name] [--use template]` | Scaffold a new Jac project via `jac create` (TUI template picker) |
| `/refactor <desc>` | Run a safe Jac refactor workflow |
| `/refactor-skill <desc>` | Run refactor flow seeded by https://www.claudedirectory.org/skills/refactor |
| `list_examples` / `get_example` (MCP) | Browse curated Jac examples via the Jac MCP |
| `/plan [prompt]` | **Toggle plan mode, or enter plan mode + send a prompt in one action** |
| `/jac-verbose [on|off]` | Toggle verbose output |
| `/subagent-model ...` | List/set model pins for subagent roles |

## CLI Flags

| Flag | Description |
|------|-------------|
| `--plan` | Start in plan mode |
| `--jac-autocheck` | Auto-check after write/edit (default: true) |
| `--jac-verbose` | Verbose retry output |
| `--jac-model` | Preferred model for Jac generation |

## Plan Mode

```
1. /plan "Analyze my Jac code"   # Enable read-only mode + send prompt in one action
2. → Creates numbered plan
3. Choose: "Execute the plan"   # Switch to full access
4. Agent executes with [DONE:n]  # Progress: 📋 3/5
5. → "Jac Plan Complete! ✓"
```

## System Prompt

Jackal's philosophy:
- **Ground decisions in evidence** — verify with `jac check`, tests, traces
- **Model spatially** — prefer nodes, edges, walkers, abilities
- **Explicit traversal** — no hidden mutations
- **Correctness first** — no invented syntax or undocumented APIs

Edit at: `jackal/SYSTEM.md`

## Allowed Tools

### Tier 1 — Core loop (constant use)

| Tool | Purpose |
|------|---------|
| `read` | Read file contents (text or images) |
| `write` | Create or overwrite files |
| `edit` | Targeted text replacement in existing files |
| `bash` | Run shell commands (`jac` CLI, `git`, `find`, etc.) |
| `jac_validate_jac` | Full type-check validation — primary correctness gate |
| `jac_check_syntax` | Parse-only syntax check (faster, no type checking) |
| `jac_run_jac` | Execute Jac code — runtime verification |

### Tier 2 — Orientation & lookup (frequent use)

| Tool | Purpose |
|------|---------|
| `jac_search_docs` | Look up Jac syntax, APIs, patterns by keyword |
| `code_overview` | Summarize project structure |
| `ast_search` | Find code matching structural patterns |
| `lsp_diagnostics` | Get compilation errors/warnings |
| `lsp_hover` | Type info and docs for a symbol |
| `lsp_definition` | Go to definition |
| `lsp_references` | Find all references |
| `lsp_completions` | Completion suggestions |

### Tier 3 — Transformation & visualization (situational)

| Tool | Purpose |
|------|---------|
| `code_rewrite` | Batch structural code transformations |
| `lsp_rename` | Rename symbol across project |
| `lsp_code_actions` | Quick fixes / refactorings |
| `lsp_symbols` | List/search symbols |
| `jac_graph_visualize` | Visualize graph output as DOT or JSON |
| `jac_get_ast` | Parse and return AST |

### Tier 4 — MCP gateway & orchestration

| Tool | Purpose |
|------|---------|
| `mcp` | Route to Jac MCP (85 tools) or browsermcp (12 tools) |
| `subagent` | Delegate to subagents: single, chain, parallel, async |

See `docs/jackal_mcp_reference.md` for full details.

### Additional Jac MCP tools (via `mcp` gateway)

| Category | Tools |
|----------|-------|
| Validation | `validate_jac`, `check_syntax` |
| Execution | `run_jac`, `format_jac`, `lint_jac` |
| Error help | `explain_error` |
| Examples | `list_examples`, `get_example` |
| Docs | `search_docs`, `get_resource` |
| AST | `get_ast` |
| Transpile | `py_to_jac`, `jac_to_py`, `jac_to_js` |
| Graph | `graph_visualize` |
| CLI | `list_commands`, `get_command`, `execute_command` |
| Learning | `understand_jac_and_jaseci` |

## Skills

- `jac-core-cheatsheet` — Jac language baseline: imports, control flow, lambdas, ternary, error handling
- `jac-types` — Type system: annotations, generics, unions, optionals, inference
- `jac-has-fields` — Typed fields on stateful archetypes
- `jac-node-edge-patterns` — Nodes, edges, connections, graph queries
- `jac-walker-patterns` — Walkers, traversal, entry points, collection, stopping
- `jac-by-llm` — Delegating function bodies to LLM calls
- `jac-impl-files` — Splitting declarations from implementations
- `jac-cl-components` — Client-side UI component patterns
- `jac-cl-organization` — Multi-component app structure
- `jac-cl-routing` — Multi-page navigation
- `jac-cl-auth` — Client-side authentication
- `jac-cl-styling` — Tailwind styling patterns
- `jac-shadcn-components` — Pre-installed jac-shadcn primitives
- `jac-npm-packages` — Adding npm packages to jac.toml
- `jac-sv-endpoints` — Server-side endpoint functions
- `jac-sv-persistence` — Graph queries from server endpoints
- `jac-sv-auth` — Server-side auth model
- `jac-fullstack-patterns` — Wiring main.jac as fullstack entry
- `jac-scaffold` — Bootstrapping new Jac projects
- `fix-skill` — Iterative error fixing workflow
- `diagnosis-skill` — Systematic diagnosis before fixing
- `osp-skill` — OSP code generation
- `project-skill` — Project structure detection
- `jackal-auth` — Authentication templates
- `refactor-skill` — Guided refactoring workflow
- `pi-subagents` — Subagent delegation patterns

## Common Workflows

### Fix compiler errors
```bash
/fix main.jac
/fix main.jac the walker fails after the refactor  # diagnosis + fix
```

### Generate OSP code
```bash
/osp Create a social graph with Person nodes and Knows edges
```

### Scaffold a new Jac project
```bash
/create                           # TUI: pick template, enter project name
/create myapp                     # Name it, then pick template
/create myapp --use client        # Skip TUI, use client template directly
/create myapp --use fullstack     # Fullstack with auth todo example
/create --force                   # Reinitialize existing project
```

### Plan a refactoring
```bash
/plan                           # Toggle plan mode on/off
/plan "I want to refactor this walker to use typed edges"
```

### Browse examples
Use the Jac MCP tools directly: run the `list_examples` tool to see example categories, then call `get_example` with a chosen example name to retrieve it.

## Project Structure

```
jackal/
├── jackal/
│   ├── SYSTEM.md      ← Custom system prompt
│   ├── mcp.json       ← Jac MCP config
│   └── settings.json
├── extensions/
│   └── jackal-toolchain.ts  ← All slash commands
├── skills/            ← Jac-specific workflows
└── prompts/           ← Reusable templates
```

## Getting Started

```bash
cd /home/jac/repos/jackal
./jackal.sh
/jac-doctor      # Verify setup
```

## Help

- Ask: "What can you do?"
- Run: `/jac-doctor` for status
- Read: `AGENTS.md` or `README.md`
