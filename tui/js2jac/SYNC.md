# js2jac (vendored snapshot)

TS/TSX → Jac converter, vendored from the WIP fork at
`~/repos/jac_llm_data/jaseci/jac/jaclang/compiler/js2jac` (untracked there; not
in canonical `jaseci`).

- **Upstream / source of truth:** the `jac_llm_data` fork — it owns the full
  207-test suite (`tests/compiler/js2jac/`), fixtures, pilot corpus, and the
  CLI wiring (`jac tool js2jac` resolves dev sources there via `sitecustomize.py`).
- **This copy:** working copy for Jackal-side slices (starting with
  ClassDeclaration lowering, `E7205`). Iterate here via the bridge loop
  (`tui/scripts/js2jac_bridge.sh`, `tui/scripts/holeconvert.mjs`); `jac check`
  (installed CLI, any cwd) validates output. The `jac tool js2jac` CLI path is
  NOT wired to this copy.
- **Sync back:** after a slice lands and passes the bridge + pi-tui floor gate,
  copy `convert_bridge.mjs` / `mapping_rules.json` / touched `impl/*.impl.jac`
  back to the fork and run the full suite there:
  `cd ~/repos/jac_llm_data/jaseci/jac && jac test tests/compiler/js2jac/`

## Re-sync snapshot here

```bash
rsync -a --exclude __pycache__ --exclude SYNC.md \
  ~/repos/jac_llm_data/jaseci/jac/jaclang/compiler/js2jac/ ./
```

Fidelity gate (last verified 2026-08-18): floor conversion of
`stdin-buffer.ts`, `terminal-colors.ts`, `components/loader.ts`, `index.ts`
byte-identical to fork output.
