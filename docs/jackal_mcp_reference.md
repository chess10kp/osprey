# Jackal Allowed Tools Reference

The canonical set of tools Jackal may use, organized by tier.

## Tier 1 — Core edit-validate-run loop (constant use)

These six tools form the **edit-validate-run loop** — the bare minimum for any coding task.

| Tool | Type | Purpose |
|------|------|---------|
| `read` | Pi built-in | Read file contents (text or images) — understand before touching |
| `write` | Pi built-in | Create or overwrite files |
| `edit` | Pi built-in | Targeted text replacement in existing files |
| `bash` | Pi built-in | Run shell commands (`jac` CLI, `git`, `find`, etc.) |
| `jac_validate_jac` | Jac direct | Full type-check validation of Jac code — primary correctness gate |
| `jac_check_syntax` | Jac direct | Parse-only syntax check (faster, no type checking) |
| `jac_run_jac` | Jac direct | Execute Jac code and return stdout/stderr — runtime verification |

## Tier 2 — Orientation & lookup (frequent use)

| Tool | Type | Purpose |
|------|------|---------|
| `jac_search_docs` | Jac direct | Look up Jac syntax, APIs, and patterns by keyword |
| `code_overview` | Pi built-in | Summarize project structure (directory tree + top-level symbols) |
| `ast_search` | Pi built-in | Find code matching a structural pattern (walkers, nodes, etc.) |
| `lsp_diagnostics` | Pi built-in | Get compilation errors/warnings from LSP |
| `lsp_hover` | Pi built-in | Get type info and docs for a symbol |
| `lsp_definition` | Pi built-in | Go to definition of a symbol |
| `lsp_references` | Pi built-in | Find all references to a symbol |
| `lsp_completions` | Pi built-in | Get completion suggestions at a position |

## Tier 3 — Transformation & visualization (situational)

| Tool | Type | Purpose |
|------|------|---------|
| `code_rewrite` | Pi built-in | Batch structural code transformations via AST matching |
| `lsp_rename` | Pi built-in | Rename a symbol across the project |
| `lsp_code_actions` | Pi built-in | Get available quick fixes / refactorings |
| `lsp_symbols` | Pi built-in | List symbols in a file or search workspace |
| `jac_graph_visualize` | Jac direct | Visualize Jac graph output as DOT or JSON |
| `jac_get_ast` | Jac direct | Parse Jac code and return AST (tree or JSON) |

## Tier 4 — MCP gateway & orchestration

| Tool | Type | Purpose |
|------|------|---------|
| `mcp` | MCP gateway | Route to Jac MCP server (85 tools: format, lint, transpile, examples, etc.) or browsermcp (12 tools) |
| `subagent` | pi-subagents | Delegate to subagents: single, chain, parallel, async execution |

### MCP servers available through `mcp` gateway

- **`jac`** — 85 tools from the Jac MCP server: validate, format, lint, explain errors, list/get examples, transpile (py↔jac↔js), graph visualization, docs search, CLI commands
- **`browsermcp`** — 12 tools for browser automation

### Subagent agents available through `subagent`

- **scout** — Fast Jac codebase recon
- **architect** — OSP graph design and planning
- **implementer** — Code implementation with full edit capabilities
- Built-in pi-subagents: planner, worker, reviewer, oracle, researcher

## Skills (loaded on demand via `read`)

30 skills covering Jac language patterns, OSP, auth, fullstack, components, scaffolding, refactoring, diagnosis. Loaded when task matches skill description.

## The Core Loop

For 80% of tasks, the workflow is:

```
read → understand context
    → write/edit the .jac file
    → jac_validate_jac (check correctness)
    → jac_run_jac (verify behavior)
    → repeat if errors
```

Everything else supports or accelerates that loop.

## Tools intentionally NOT exposed as direct tools

These are available through the `mcp` gateway when needed, but are not primary tools:

- `jac_format_jac` — auto-format hooks take care of this
- `jac_lint_jac` — rarely needed directly
- `jac_py_to_jac` / `jac_jac_to_py` / `jac_jac_to_js` — transpilation is situational
- `jac_list_commands` / `jac_get_command` / `jac_execute_command` — `bash` with `jac` CLI covers this
- `jac_get_resource` / `jac_list_examples` / `jac_get_example` — `jac_search_docs` + Jac guide cover this
