# pi-tui → Jac via js2jac (baseline run)

**Source:** `~/repos/notes/reference/pi/packages/tui` (`@earendil-works/pi-tui`, ~19.6k LOC in `src/`).

**Converter:** `jac_llm_data/jaseci/jac` (`jac tool js2jac`, bridge `holeconvert.mjs` with `failOpen` + `emitHoles`).

**Date:** 2026-08-18

## Summary

js2jac is a strong baseline for **React function components** (Pilot A corpus). pi-tui is a **class-based terminal framework** with Node builtins (`node:fs`, `process`, `EventEmitter`, native `.node` helpers). The deterministic converter does **not** yet lower that shape.

| Mode | Files | Notes |
|------|------:|-------|
| `src/*.ts` total | 28 | excludes `test/` |
| Strict project write (`--write`, `--fail-open`) | **2** emitted | `stdin-buffer.jac`, `terminal-colors.jac` — both `jac check` pass |
| Floor batch (`holeconvert`, holes kept) | **13** emitted | partial Jac with `# JS2JAC-HOLE` markers |
| Floor `jac check` pass | **5 / 13** | holes or missing decls break syntax |
| Hard reject (no Jac at all) | **15 / 28** | normalize stage |

**Bottom line:** Running js2jac alone does **not** produce a usable pi-tui port today. The gap is structural (classes + Node server runtime), not volume.

## Dominant rejection codes

| Code | Meaning | pi-tui impact |
|------|---------|----------------|
| **E7205** | Unsupported `ClassDeclaration` (and non-component `export const`) | Almost every `Component` class (`Spacer`, `Text`, `TUI`, `Editor`, …) |
| **E7215** | Unsupported expression/literal in body | `++`/`--`, `{}` sentinels, some Node patterns |
| **E7230** | Unsupported top-level form | e.g. `for` loops at module scope in `fuzzy.ts` |
| **E7232** | Helper needs TS type annotation | untyped helper params in `utils.ts` |
| **E7200** | Declaration produced no output | type predicates (`is Focusable`), some exports |

Example (spacer — smallest component):

```
E7205: Unsupported declaration: ClassDeclaration
```

## Artifacts in this repo

| Path | Contents |
|------|----------|
| `pi_jac/` | Strict project-mode output (2 files + `js2jac_report.json`) |
| `pi_jac_floor/` | Per-file floor Jac for 13 modules (holes preserved) |
| `pi_jac_floor_summary.json` | Per-file status, hole counts, `jac check` results, reject codes |

### Floor files that pass `jac check` (starting points)

- `src/index.jac` — re-export barrel (no holes)
- `src/stdin-buffer.jac` — escape-sequence completeness helpers (3 holes in source, still checks)
- `src/terminal-colors.jac` — `hexToRgb` (uses `parseInt` — server codespace)
- `src/components/loader.jac` — partial loader (1 hole)
- `src/components/editor.jac` — large partial editor (8 holes)

### Largest partial floors (need class + Node interop work)

- `src/tui.jac` — `Container`/`TUI` classes left as holes; imports still point at `.ts` paths
- `src/utils.jac` — 23 holes (ANSI width, `AnsiCodeTracker` class, `Intl`/`Map` exports)
- `src/keys.jac` — 19 holes (keyboard protocol parsing)

## Python runtime mismatch

Even converted fragments assume **Node** (`import from "node:fs"`, `process.env`, `performance`, `parseInt` as global). A Jackal Jac TUI should use **server-anchored Python stdlib** (`termios`, `tty`, `select`, `sys.stdin`/`stdout`) via `::py::` blocks or thin bridge modules — same pattern as `lib/jac/` in Jackal.

`jac check` may pass while **native lowering fails** (e.g. `parseInt` → E5092); those modules compile in the server codespace only.

## Recommended next steps

1. **js2jac slice (jac_llm_data):** ClassDeclaration → Jac `obj` / methods (V2.10+). This unlocks ~15 hard-rejected files and holes inside `tui.jac`, `utils.jac`, etc.
2. **Node → server interop track:** `node:*` imports, `process`, `Buffer`, `EventEmitter` → Python stdlib or `::py::` shims (not in current client intent).
3. **Hole-fill:** `scripts/js2jac_holepatch.py` on floor files after class lowering — LLM fills `# JS2JAC-HOLE` blocks, `jac check` gates.
4. **Parallel track:** Hand-build the thin foundation you outlined (`terminal.jac`, `renderer.jac`, `component.jac`, `editor.jac`) and port pi-tui **by module** with tests, using floor Jac as reference — likely faster than waiting for full automated conversion.

## Re-run

```bash
./tui/scripts/js2jac_pi_tui.sh
```

Uses `jac` from `jac_llm_data/jaseci/jac` (dev compiler) and writes `pi_jac_floor/` + summary.
