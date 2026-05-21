# Jackal Next Agent

This directory contains the in-repo implementation of the new Jac-inspired coding agent.

## Goals
- Replace current behavior with an Ink/TUI-driven agent runtime flow.
- Keep Pi/Jac interoperability, but make Jackal the first-class host.
- Build incrementally with verifiable checkpoints.

## Current Phase
- Phase 0: headless runtime spike + architecture seam verification.
- Phase 1: dependency wiring and runtime adapter scaffolding.

## Immediate tasks
1. Add a runtime spike script under `docs/`.
2. Define adapter API in `src/`.
3. Add template emitters in `templates/`.
4. Integrate with existing extension entrypoint after smoke tests pass.
