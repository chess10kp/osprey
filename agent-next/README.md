# Jackal Next Agent

This directory contains the in-repo implementation of the new Jac-inspired coding agent.

## Goals
- Replace current behavior with an Ink/TUI-driven agent runtime flow.
- Keep Pi/Jac interoperability, but make Jackal the first-class host.
- Build incrementally with verifiable checkpoints.

## Current Phase
- Phase 5/6 hardening: stabilize shell loop, auth/model overlays, tool timeline, persistence.

## Milestone 1 smoke run
Build the adapter and launch the shell:

```bash
npm run build:agent
node agent-next/templates/shell.mjs
```

Shell commands in current milestones:
- `/login [provider]` start auth flow (opens picker when provider omitted)
- `/logout <provider>` logout provider
- `/model [provider/model]` open model picker or set directly
- `/cancel` cancel auth flow
- `/abort` cancel active run
- `/clear` start a new persisted session (clears local transcript)
- `/exit` quit and dispose session

Shell also renders a live tool timeline (running/done + truncated result preview) and footer tool counters.

Session history is now disk-backed via Pi SessionManager and restored on startup.
