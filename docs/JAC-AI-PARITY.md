# `jac ai` vs Jackal — Feature Parity

**Reference:** [`reference/jaseci/jac/jaclang/cli/`](../reference/jaseci/jac/jaclang/cli/) — `ai_agent.jac`, `commands/ai.jac`, `agent_api.jac`  
**Jackal:** `./jackal.sh` — TypeScript runtime (`src/`) + Ink shell (`templates/shell.cl.jac`)  
**Last reviewed:** 2026-05-25

`jac ai` is the interactive Jac coding agent behind the `jac ai` CLI command: a byLLM ReAct loop with file tools, bundled reference guides, and compiler-backed semantic navigation. Jackal is a fuller terminal product (Ink TUI, sessions, MCP, subagents, plan mode).

**Legend:** ✅ Done · 🟡 Partial · ❌ Missing · ➖ Different by design

---

## Executive summary

| Area | `jac ai` | Jackal |
|------|----------|--------|
| **Semantic navigation** | ✅ `CodeIntelligence` tools | ❌ LSP position tools only; no `CodeIntelligence` |
| **Write-time compiler feedback** | ✅ `refresh_and_diff` on every write | 🟡 autocheck via `.jackal`; no per-write delta |
| **Bundled Jac guides** | ✅ `search_guides` / `read_guide` + prompt index | 🟡 `pi/skills/` on demand + MCP docs |
| **Agent runtime** | Jac + byLLM (local default) | TypeScript + pi-agent-core (cloud auth) |
| **TUI & sessions** | ❌ plain console REPL | ✅ Ink, persist, `/resume` |
| **MCP & subagents** | ❌ | ✅ |
| **Plan mode, checkpoints, tasks** | ❌ | ✅ |

**Bottom line:** Jackal is ahead as a **terminal product**. `jac ai` is ahead as a **Jac-native, compiler-grounded agent** inside the toolchain.

---

## What `jac ai` has that Jackal does not

### 1. Compiler-backed semantic navigation (`CodeIntelligence`)

`jac ai` wires a shared `CodeIntelligence` handle (`agent_api.jac` → `run_agent`) and exposes **name-based** tools backed by the Jac compiler symbol table, not grep or LSP cursor positions:

| Tool | Purpose |
|------|---------|
| `find_symbol` | Exact definitions by symbol name |
| `find_uses` | All uses of a symbol |
| `project_map` | Structural overview of the project |
| `find_walkers` | Walkers that traverse a node type |
| `context_slice` | Typed neighborhood around a symbol |

Jackal has **LSP tools** (`diagnostics`, `hover`, `definition`, `references`) that require file + line + character. It does **not** use `CodeIntelligence` anywhere in this repo. Docs mention `ast_search` / `code_overview` in `AGENTS.md`, but they are **not** implemented in `src/agent/tools.ts`.

| Gap | Priority |
|-----|----------|
| Wire `CodeIntelligence` (or equivalent) | High |
| Expose semantic navigator tools | High |

**`jac ai` refs:** `reference/jaseci/jac/jaclang/compiler/code_intel.jac`, `ai_agent.jac` (semantic tools section)

---

### 2. Automatic compiler feedback on every write

After `write_file` / `edit_file`, `jac ai` calls `write_feedback()` → `CodeIntelligence.refresh_and_diff(path)` and appends **delta diagnostics** (errors/warnings this edit caused, including cross-file breakage) to the tool result.

Jackal can autocheck via `.jackal` when enabled, but there is no equivalent **inline, per-write delta feedback** tied to the compiler project model.

| Gap | Priority |
|-----|----------|
| Per-write `refresh_and_diff` on `write` / `edit` | High |

---

### 3. Bundled `guide_store` as first-class tools

`jac ai` ships **21** CLI skills under `jaclang/cli/skills/` as `search_guides` / `read_guide`, with the guide index and **jac-core-cheatsheet** baked into the system prompt.

Jackal uses **`pi/skills/`** (26 skills) loaded on demand via `read` + a skill index in `SYSTEM.md`, plus Jac MCP `search_docs` / `get_resource`. Same intent, different packaging — `jac ai` treats guides as native tools and prompt content.

| Gap | Priority |
|-----|----------|
| First-class guide tools or tighter `guide_store` integration | Medium |

---

### 4. byLLM-native agent loop

| Feature | `jac ai` | Jackal |
|---------|----------|--------|
| ReAct loop | `ask`, `max_react_iterations=80` | pi-agent-core |
| Parallel tool batches | `parallelize=True` + `mark_serialize()` on mutating tools | Subagent parallel only; not main-loop byLLM-style |
| Stream reasoning | `thought` + `chunk` events to stdout | Assistant stream in Ink |
| Per-turn stats | `/stats`: duration, tools, files, tokens, **USD estimate**, project health | `/usage` context bar; no per-turn cost/health line |
| Turn health | `_format_health()` from `CodeIntelligence` | ❌ |

---

### 5. Local-first model path

Default model is **`local:gemma-4-e4b`** (no API key). Supports `--model`, `--n_ctx`, and `[plugins.byllm.local]` (threads, GPU layers, etc.) from `jac.toml`.

Jackal is oriented around **pi-ai** cloud auth (OAuth/API keys in `auth.json`). Local byLLM models are not the default launch path.

| Gap | Priority |
|-----|----------|
| Optional local-byLLM path aligned with `jac.toml` | Medium (product choice) |

---

### 6. Dedicated QA / app-boot tools

| Tool / behavior | `jac ai` | Jackal |
|-----------------|----------|--------|
| `start_app` | Runs `jac start` ~12s, returns startup logs | ❌ — use `jac_run` / bash |
| Browser QA | System prompt mandates `agent-browser` for web/fullstack | ❌ — not in core agent rules |
| QA pass in prompt | Mandatory `jac check` + `start_app` + browser before “done” | Partial via skills / user workflow |

---

### 7. Minimal CLI surface & pluggable hook

| Feature | `jac ai` | Jackal |
|---------|----------|--------|
| UI | Rich console REPL (`> `) | Ink TUI |
| Slash commands | `/help`, `/clear`, `/guides`, `/stats`, `/exit` | Full slash registry |
| One-shot | `jac ai "prompt"` | `jackal run` |
| Pluggable agent | `run_ai_agent` hook — plugins replace agent | `./jackal.sh` only |
| Hard dependency on byLLM | Lazy import in `ai` command | pi-agent-core always |

---

### 8. Jac-specific agent rules in the core prompt

`AGENT_RULES` in `ai_agent.jac` includes:

- Scaffold via `jac create` (not hand-built layout)
- Navigate by meaning (`find_symbol`), not grep, for symbols
- Jac gotchas: no `pass`, docstring placement, lowercase `any`
- Mandatory QA pass before reporting done

Jackal’s `pi/SYSTEM.md` emphasizes evidence, OSP, and skills but does not embed this **`jac ai`-specific QA/scaffold contract**.

---

## What Jackal has that `jac ai` does not

### Terminal product & UX

| Feature | Jackal | `jac ai` |
|---------|--------|----------|
| Ink TUI | ✅ status bar, overlays, tool timeline | ❌ plain text |
| Session persistence | ✅ disk, `/resume`, retention, export | ❌ in-memory `history` only |
| Streaming in rich UI | ✅ `streammsg` / markdown | ✅ raw stdout tokens |
| Tool approval UI | ✅ queue + overlays | 🟡 `--safe` prompts in terminal |
| Mermaid in chat | ✅ | ❌ |
| Notifications | ✅ | ❌ |

### Agent platform

| Feature | Jackal | `jac ai` |
|---------|--------|----------|
| MCP (`jac mcp`) | ✅ lazy connect, 19+ tools | ❌ |
| Subagents + chains | ✅ scout / architect / implementer | ❌ |
| Dev modes | ✅ normal / auto-accept / yolo / plan / ask | 🟡 yolo default; `--safe` only |
| Checkpoints | ✅ snapshots + `/checkpoint` | ❌ |
| Task management | ✅ tools + `/tasks` | ❌ |
| Custom commands | ✅ `.jackal/commands/*.md` | ❌ |
| `.jackal` config | ✅ autocheck, plan, sessions, … | 🟡 `jac.toml` byllm only |
| Non-interactive CLI | ✅ `jackal run` (--mode, --plain) | 🟡 `jac ai "…"` one-shot |
| Web tools | ✅ `web_search`, `web_fetch` | ❌ |

### Jac toolchain (Jackal-specific tools)

| Tool | Jackal | `jac ai` |
|------|--------|----------|
| `jac_fix` | ✅ bounded fix loop | ❌ |
| `jac_test` | ✅ | ❌ (via `run_command`) |
| `jac_format` | ✅ | ❌ |
| `jac_doctor` | ✅ | ❌ |
| `jac_create` / `jac_list_templates` | ✅ | ❌ (prompt says `run_command`) |
| `glob` | ✅ | ❌ (`list_dir` + `grep`) |

### Context & compression

| Feature | Jackal | `jac ai` |
|---------|--------|----------|
| `@file` mentions + line ranges | ✅ | ❌ |
| `!command` inline bash → context | ✅ | ❌ |
| `/explorer` | ✅ | ❌ |
| Auto-compact / `/compact` | ✅ LLM + mechanical | ❌ |
| `/usage` | ✅ | ❌ |

---

## Overlap (both have, different shape)

| Capability | `jac ai` | Jackal |
|------------|----------|--------|
| Read / write / edit | `read_file`, `write_file`, `edit_file` | `read`, `write`, `edit` |
| Shell | `run_command` | `bash` |
| Type-check | `jac_check` | `jac_check` + MCP `validate_jac` |
| File search | `grep` (`.jac` only), `list_dir` | `glob` + bash |
| Learning / docs | `search_guides`, `read_guide` | skills + MCP `search_docs` |
| Confirm side effects | `--safe` (opt-in) | dev modes + approval (opt-out in yolo) |
| One-shot prompt | `jac ai "…"` | `jackal run` |

---

## Suggested Jackal gaps (if targeting `jac ai` parity)

| # | Item | Effort | Notes |
|---|------|--------|-------|
| 1 | Wire `CodeIntelligence` + semantic tools | Large | May call into jaclang from TS or port to Jac later |
| 2 | Per-write `refresh_and_diff` on `write`/`edit` | Medium | Depends on (1) |
| 3 | `guide_store` tools or unified guide index in prompt | Small–medium | Reuse `jaclang/cli/guide_store` |
| 4 | `start_app`-style QA tool | Small | Wrapper around `jac start` |
| 5 | Local byLLM model path | Medium | Product/auth decision |
| 6 | Browser QA guidance in `SYSTEM.md` | Small | Docs/prompt only |

---

## Related docs

- [FEATURES.md](./FEATURES.md) — Jackal required features checklist
- [NANOCODER-PARITY.md](./NANOCODER-PARITY.md) — nanocoder vs Jackal
- [CURSOR_PARITY.md](../CURSOR_PARITY.md) — Cursor CLI vs Jackal
- [JAC-CORE-MIGRATION.md](./JAC-CORE-MIGRATION.md) — future Jac-native runtime
- [AGENTS.md](../AGENTS.md) — Jackal agent rules
