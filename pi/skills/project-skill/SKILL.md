---
name: project-skill
description: Detect and understand Jac/Jaseci project structure, toolchain, and conventions. Use when working with .jac files or when the user mentions Jac, Jaseci, or jaclang.
---

# Jac Project Detection

When working on a Jac project, follow these steps to understand the project:

## 1. Check for Jac installation

Run `/jac-doctor` to verify the Jac CLI is available and detect `.jac` files in the project.

## 2. Look for project config

Check for `jac.toml` in the project root — it defines project metadata, entry points, and dependencies (similar to `package.json` or `pyproject.toml`).

## 3. Identify entrypoints

Common entrypoint files:
- `main.jac` — default entry point
- `app.jac` — web/full-stack app entry point
- Any `.jac` file with a walker that serves as the root execution target

Look for a `[tool.jac.project]` section in `jac.toml` that may specify `entry_point`.

## 4. Understand project type

- **Basic**: standalone `.jac` files, no `jac.toml`
- **Backend**: has `jac.toml`, Python runtime, REST API via `jac start`
- **Full-stack**: has both Python and JS dependencies, client/server structure
- **Graph app**: focuses on nodes, edges, walkers with graph traversal

## 5. Use the tools

All Jac toolchain behaviour is provided by the **Jac MCP server** (configured in `jackal/mcp.json`). The most important MCP tools:

| Need                        | MCP tool                                       |
| --------------------------- | ---------------------------------------------- |
| Validate / type-check       | `validate_jac`                                 |
| Fast parse-only check       | `check_syntax`                                 |
| Format / lint               | `format_jac` / `lint_jac`                      |
| Explain a compiler error    | `explain_error`                                |
| Browse curated examples     | `list_examples` → `get_example`                |
| Search docs                 | `search_docs` / `get_resource`                 |
| Run a Jac program           | `run_jac`                                      |
| Visualise a graph           | `graph_visualize`                              |
| Inspect AST                 | `get_ast`                                      |
| Transpile                   | `py_to_jac` / `jac_to_py` / `jac_to_js`        |
| Discover / run CLI commands | `list_commands` / `get_command` / `execute_command` |

Always prefer these MCP tools over shelling out to `jac` directly.

Jackal slash commands (host-side workflow helpers):
- `/jac-doctor` — check environment, MCP availability, model, autocheck/verbose flags, .jac files
- `/jac-check [file]` — run `jac check` and display diagnostics in the TUI
- `/fix [file] [description]` — run `jac check` + ask the agent to fix errors via the MCP (3-attempt cap). If you describe the issue, the agent follows `diagnosis-skill` first, then `fix-skill`.
- `/osp <description>` — generate Object-Spatial code (walker/node/edge) via the MCP
- `/plan [prompt]` — toggle plan mode, or enter plan mode and send a prompt in one action
- Use the Jac MCP tools `list_examples` / `get_example` to browse curated examples (no host-side slash command).
- `/jac-verbose [on|off]` — toggle verbose output in slash-command notifications
- `/jac-model [name]` — show or set the preferred model for Jac generation

Auto-check: every `write` or `edit` to a `.jac` file triggers a background `jac check`.
If errors are reported, the agent gets a follow-up message asking it to fix them
(capped at 3 attempts per file). Disable with `--jac-autocheck=false`.

## 6. Common file patterns

- `*.jac` — Jac source files
- `.jac/` — generated/build artifacts (check gitignore)
- `jac.toml` — project configuration
- `requirements.txt` or `pyproject.toml` — Python deps (Jac runtime requires Python)
- `package.json` — JS deps (for full-stack projects)
