# Jackal in the `na` codespace — exploration findings

**Date:** 2026-08-16 · **Trigger:** plugin system dropped from jaclang → jac-ink / `jac tui` / `.cl.jac` all dead. **Decision:** pivot — write the whole harness in Jac, native-first.

All claims below were verified live against the installed toolchain (spike in `/tmp/na-spike`), not read from stale docs.

---

## 1. What changed in the Jac world

| Fact | Evidence |
|---|---|
| Plugin system **gone** | `jac tui` → invalid choice; jac-ink registered via `[project.entry-points."jac"]` which no longer loads |
| `.sv.jac` / `.cl.jac` / `.na.jac` **retired** | `jac fix placement` strips markers + renames files; marker syntax is now a compile error |
| Placement is **inferred, markerless** | JSX/npm imports → client; Python imports/graph archetypes/`::py::` → server; extern C → native; `[placement.pins]` in jac.toml overrides |
| `na` is the **default codespace** for anchor-free modules | `[build] default_codespace = "native"` is the default under `jac run` |
| `jac ai` + byllm are **built-in** | `import from jaclang.byllm.lib { Model }` — vendored in jaclang, no pip dep needed |
| **No TUI client target** | `--client {web,pwa,static,mobile,desktop,cef,react-native}` — terminal is not a first-class target |

## 2. Spike results (all verified)

```bash
$ jac nacompile tool.jac -o tool && ./tool Native
Hello, Native!                       # 277 KB zero-dependency binary

$ jac check --placements mixed.jac
hot.jac  [decided native]            # anchor-free module → native, free
  diff_tokens (Ability)    native
mixed.jac
  <entry> (ModuleCode)     server    # import os; anchors server

$ jac run mixed.jac
cwd: /tmp/na-spike                   # server-side Python works
native hot call: 2                   # native called from server, auto-bridged

$ jac run bytest3.jac                # Model(model_name="mock") via
model ok: True                       # jaclang.byllm.lib — LLM edge works
```

## 3. What native (`na`) supports vs. blocks

**Works natively** (per `jac-native` guide, subset verified by nacompile):
collections/objects/enums/exceptions, `open/read/write` file I/O, `input`/`print`,
str methods, `os.system`, `os.path` subset (join/exists/isdir/getsize…),
`math`/`time`/`sys`/`random`, **C FFI** (`import from raylib { def InitWindow(...) -> None; }` — any `.so`),
native→native IR-level imports, decl/impl split, mixed-file native sections
auto-bridged both directions to Python.

**Blocked natively** (loud compile errors): `by llm()`, PyPI/litellm, `::py::`,
walkers/nodes/edges, async, generators, `import json`, sockets, `os.listdir`,
lambda captures (silently wrong!), `input` beyond line-oriented.

**Consequences for a harness:**
- LLM edge must live **server** (vendored byllm) — or, stretch, hand-rolled JSON + libcurl FFI.
- `glob` tool needs FFI `opendir` or a server bridge.
- bash output capture needs FFI `popen` or server `subprocess`.
- Rich TUI = FFI termios/ncurses later; `input()`/`print` REPL works day one.

## 4. Ecosystem incompatibilities found (gotchas for the port)

1. **Syntax drift**: module-level Jac-module imports take **no `;`**; Python imports keep `;`;
   no `global` statement anymore (bare assignment rebinds `glob`s).
2. **`reference/jaseci/.../ai_agent.jac` is legacy syntax** (old semicolons, `byllm.lib` import,
   `ask()` API). Port patterns, not code. New Model API: `dispatch_streaming_with_tools`, `ainvoke`, …
3. **pip `byllm` 0.6.x is broken** against current jac (removed `by postinit` markers in its own
   `.jac` files). Use the vendored `jaclang.byllm.lib` only.

## 5. Target architecture

One Jac program. No Node, no TypeScript, no bridge, no plugin.

```
jackal/
├── main.jac              # entry + REPL (server-anchored: byllm, subprocess, input())
├── agent/
│   ├── session.jac       # ReAct loop via Model.dispatch_streaming_with_tools,
│   │                     #   StreamEvent render, history, usage accounting
│   ├── tools.jac         # read_file, write_file, edit_file, bash, jac_check…
│   └── system.jac        # system prompt + guide/skill grounding (sem strings)
├── core/                 # anchor-free modules → compiled NATIVE by default
│   ├── diff.jac          # edit/merge engine (hot path)
│   ├── parse.jac         # file-mention, slash-command, frontmatter parsing
│   ├── tokens.jac        # token estimation
│   └── render.jac        # markdown → ANSI renderer
└── jac.toml              # [project], [placement.pins] if inference is wrong
```

Placement does the dogfooding for us: every `core/` module is anchor-free →
`jac check --placements` must show `[decided native]`. That is the acceptance bar.

**Stretch (Phase N4):** hand-rolled JSON codec + libcurl FFI for the LLM HTTP edge
→ `jac nacompile -o jackal` ships Jackal as a single zero-dependency binary.

## 6. Phased plan

| Phase | Deliverable | Acceptance |
|---|---|---|
| **N0** REPL loop | `main.jac` + `agent/` on server codespace: streaming turns, read/write/edit/bash tools, `/help` `/exit` | `jac run main.jac` completes a 3-turn session that edits a file |
| **N1** Native core | `core/diff.jac`, `core/parse.jac`, `core/tokens.jac` | `--placements` shows each `[decided native]`; called from N0 loop |
| **N2** Surface | sessions (jsonl persistence), slash commands, jac check/format integration, dev modes (yolo/safe) | restart restores session; `/fix` loop works |
| **N3** TUI growth | Rich (server) or FFI termios raw-mode + ANSI renderer (`core/render.jac` native) | live streaming render, tool timeline, Ctrl-C abort |
| **N4** Single binary | JSON codec + libcurl FFI LLM edge; everything else already native | `jac nacompile -o jackal && ./jackal` full session |

## 7. What dies / what gets re-ported

- **Dies:** `src/` TS runtime (~13k LOC), `templates/*.cl.jac` (4.5k LOC), jac-ink dependency,
  `.jac/tui` compile + all `postprocess_tui` workarounds, the Python stdio bridge + worker
  (BRIDGE-REMOVAL-PLAN Phases 2–3 become moot — there is no second process to bridge).
- **Re-ported progressively from TS:** session persistence, checkpoints, skills, subagents,
  custom commands, permission modes, MCP (via `jac mcp` CLI subprocess), context compaction.
- **Regression accepted initially:** Ink TUI → line-oriented REPL (N0–N2), TUI regrows in N3.

## 8. Open questions (human)

1. Accept line-oriented UX for N0–N2 while the TUI regrows, or is Rich a N0 requirement?
2. Dual-track (keep TS Jackal runnable) during N0–N1, or hard pivot in-repo?
3. MCP via `jac mcp` subprocess — acceptable, or push for an in-process surface?
