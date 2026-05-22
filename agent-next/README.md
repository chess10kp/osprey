# Jackal Next Agent

This directory contains the in-repo implementation of the new Jac-inspired coding agent.

## Goals
- Replace current behavior with a **jac-ink / Ink** agent runtime flow.
- Keep Pi/Jac interoperability via `@jac/pi` and the headless TS adapter.
- Build incrementally with verifiable checkpoints.

## UI stack

**Renderer:** [jac-tui](https://github.com/jaseci/jac-tui) (`~/repos/jac-tui`) — the **jac-ink**
plugin compiles `.cl.jac` into an Ink + React terminal app (`jac tui`, `jac jac2ink --with_pi`).

**Shell UI:** `templates/shell.cl.jac` exports `app()` and owns all terminal rendering.

**Agent runtime:** `src/*.ts` → `dist/*.js` — headless Pi session, store, auth, and event bridge.
Wires into jac-ink via `@jac/pi` (see jac-tui `docs/pi-interop-plan.md`).

| Layer | Location | Notes |
|-------|----------|-------|
| Ink UI | `templates/shell.cl.jac` | Runtime — `app()` + Ink components |
| Pi adapter | `src/*.ts` → `dist/*.js` | Headless session/store/auth |
| jac-ink | `~/repos/jac-tui/jac-ink` | Compiler, `--with_pi`, runtime shims |

## Current Phase
- Phase 6: wire `shell.cl.jac` to the adapter via `@jac/pi`; launch via `jackal.sh`.

## Smoke run

```bash
npm run build:agent
cd agent-next && jac tui templates/shell.cl.jac --with_pi --install --run
```

Or from repo root:

```bash
./jackal.sh
```

Shell commands (implement in `shell.cl.jac`):
- `/login [provider]` start auth flow
- `/logout <provider>` logout provider
- `/model [provider/model]` model picker or direct set
- `/cancel` cancel auth flow
- `/abort` cancel active run
- `/clear` new persisted session
- `/multiline` toggle multiline input
- `/help` command palette
- `/exit` quit and dispose

Target UX: live tool timeline, autocomplete, scrollback, multiline input, disk-backed
session history via Pi SessionManager.
