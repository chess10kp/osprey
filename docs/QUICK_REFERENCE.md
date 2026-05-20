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

## Jac MCP Tools

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

- `fix-skill` — Iterative error fixing workflow
- `diagnosis-skill` — Systematic diagnosis before fixing when the user describes an issue
- `osp-skill` — OSP code generation
- `project-skill` — Project structure detection
- `jackal-auth` — Authentication templates
- `refactor-skill` — Guided refactoring workflow

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
