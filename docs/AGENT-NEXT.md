# Jackal Agent Runtime

In-repo **Jac-ink / Ink** coding agent shell with a headless TypeScript runtime. **This is Jackal** — there is no separate “classic” or Pi-based launch path in active development.

## Goals

- **jac-ink / Ink** terminal UI (`templates/shell.cl.jac`)
- **Jackal-native runtime** — `pi-agent-core` + `pi-ai` only (no `pi-coding-agent`)
- Incremental, verifiable checkpoints

## UI stack

| Layer | Location | Notes |
|-------|----------|-------|
| Ink UI | `templates/shell.cl.jac` | `app()` + Ink components |
| Agent runtime | `src/*.ts` → `dist/*.js` | Store, auth, `pi-agent-core` loop |
| Runtime hooks | `@jac/pi` via jac-ink | Virtual module; shim emitted by **jac-ink** (human-maintained) |
| jac-ink | `~/repos/jac-tui/jac-ink` | Compiles `.cl.jac` → Ink app |

The `@jac/pi` import name is a **jac-ink virtual module** for React hooks. It does **not** load `pi-coding-agent`. Framework/plugin changes (jac-ink, jaclang) are **human-owned** — see [`docs/JAC-TUI.md`](docs/JAC-TUI.md) and [`../AGENTS.md`](../AGENTS.md).

## Docs

- [docs/FEATURES.md](docs/FEATURES.md) — required features + status
- [docs/PLAN.md](docs/PLAN.md) — phases
- [docs/JAC-TUI.md](docs/JAC-TUI.md) — jac-tui handoff checklist

## Dependencies

- `@earendil-works/pi-agent-core` — agent loop (`Agent` class)
- `@earendil-works/pi-ai` — models, streaming, OAuth helpers
- Declared in `jac.toml` and `package.json`

## Run

```bash
npm run build:agent
./jackal.sh
```

Or manually:

```bash
npm run build:agent
jac tui templates/shell.cl.jac --install --run
```

(`jackal.sh` builds the adapter, runs `jac tui` to compile the shell, then `node .jac/tui/runner.mjs`. Requires an interactive terminal.)

Auth uses `pi/auth.json` (symlinked from `~/.pi/agent/auth.json` on first launch — see `jackal.sh`).

## Shell commands

- `/login [provider]` — start auth flow
- `/logout <provider>` — logout provider
- `/model [provider/model]` — model picker or direct set
- `/cancel` — cancel auth flow
- `/abort` — cancel active run
- `/clear`, `/new` — new session
- `/multiline` — toggle multiline input
- `/help` — command palette
- `/exit` — quit and dispose
