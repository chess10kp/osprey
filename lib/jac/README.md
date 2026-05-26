# Jackal Jac core (migration target)

Server-side Jac modules replacing the TypeScript headless runtime (`src/` → `dist/`).

## Status

| Phase | State |
|-------|--------|
| 0 — Feasibility spike | Done — import/instantiate + one headless turn (`agent_spike.jac` → `npm_agent_spike.mjs`) |
| 1 — Toolchain modules | In progress — `jac/{types,cli,doctor,workflows,lsp_config}.jac`, `main.jac`, tests |
| 2–5 | Not started — see [docs/JAC-CORE-MIGRATION.md](../../docs/JAC-CORE-MIGRATION.md) |

## Commands

```bash
# CI: toolchain + npm agent loop + Jac test harness
npm run check:jac
# or: ./scripts/jac-toolchain-check.sh

# Jac-only unit tests (runs lib/jac/tests/*_test.jac per-file)
npm run test:jac
# or: ./scripts/jac-test-harness.sh

# Individual steps
jac run lib/jac/spike/agent_spike.jac   # Phase 0 spike only (verbose)
jac run lib/jac/main.jac -- --check      # doctor + jac check + headless turn
jac check lib/jac/jac
```

## npm interop note

Jac cannot import ESM `pi-agent-core` directly today. The spike uses a **Node bridge** (`npm_agent_spike.mjs`) until in-process Jac/npm interop lands (jaclang or jac-ink).

## TypeScript wiring

`src/jac/jac-cli.ts`, `jac-doctor.ts`, `jac-workflows.ts`, `jac-types.ts`, and `lsp-service.ts` (config only) delegate to `lib/jac/jac/_*_toolchain.py` via `lib/jac/bridge/toolchain_stdio.py` (JSON stdio). Sync bridge calls avoid ~3s `jac run` per autocheck while keeping a single Python implementation shared with `.jac` modules.

LSP **transport** (`lsp-client.ts`, `lsp-tools.ts`, `JacLspService`) remains in TypeScript until Phase 4 — it depends on `vscode-languageserver-protocol` on Node.

## Layout

```
lib/jac/
├── main.jac              # --check entry
├── bridge/
│   └── toolchain_stdio.py  # TS ↔ Python JSON bridge
├── jac/
│   ├── _cli_toolchain.py
│   ├── _doctor_toolchain.py
│   ├── _workflows_toolchain.py
│   ├── _lsp_toolchain.py   # resolve_lsp_config only
│   ├── _npm_bridge.py
│   ├── cli.jac
│   ├── doctor.jac
│   ├── workflows.jac
│   ├── lsp_config.jac
│   └── types.jac
├── spike/
│   ├── agent_spike.jac
│   └── npm_agent_spike.mjs
└── tests/
    └── cli_test.jac
```
