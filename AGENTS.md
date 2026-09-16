# Osprey — Agent onboarding (read this first)

Jac-native terminal UI framework (OSP): a retained semantic UI graph, a
constraint-based layout engine, and a damage-tracked renderer, authored in
Jac with native lowering as the default target (`app/jac.toml` sets
`default_codespace = "native"`).

---

## Rules for agents working in this repo

1. **Commit** after each feature or bugfix (unless the user says otherwise).
2. **Do not modify** `jac-client`. **Exception — vendored compiler:**
   `vendor/jac/` (subtree of jaseci-labs/jac, see
   [`docs/VENDOR-JAC.md`](docs/VENDOR-JAC.md)) is ours to fix: native-path
   fixes land there first so framework work never waits on upstream PR
   latency. Keep vendor changes upstream-able and sync them back.
3. **Native lowering discipline:** write Jac that lowers natively — annotate
   types (including kwargs and intermediates) so modules lower without
   implicit server fallback; keep `jac build` green on `app/`; change
   `[placement.pins]` in `app/jac.toml` only via deliberate commits with a
   stated reason.
4. **Framework gaps** → stop, document symptom + owning repo + minimal
   recommended fix for the **human**.

---

## Quick start (dev)

```bash
cd app
jac run ui/demo_live_shell.jac   # interactive demo shell (needs a TTY)
jac build                        # native compile check over app/
jac test ui/<module>.test.jac    # per-file jac tests
./scripts/jac-test-harness.sh    # sweep every *.test.jac under app/
```

**Requirements:** Python env with `jac` CLI (vendored compiler under
`vendor/jac/`, wrapper in `scripts/setup-vendor-jac.sh`); a TTY for the
live demo.

---

## Architecture (one picture)

```
app/ui/  OSP framework
  ├─ model/mutation/bindings/events   semantic UI graph (typed edges)
  ├─ terminal + virtual_terminal      process / in-memory hosts
  ├─ renderer/screen/transcript       retained damage-tracked paint
  ├─ editor                           multiline draft, caret, selection
  ├─ layout (+ measure/quantize/compile)
  ├─ markup/markdown_proj             tag lowering + markdown projection
  └─ focus, gates, keybinding, widgets
        │
        ▼
app/constraints/  constraint solver (algebra, relations, solver, oracle)
app/cordis/       composition core (revertible effects + reactive coeffects)
app/core/         edit/diff kernel (natively pinned)
```

- **Placement:** `core.edit`, `constraints.*`, and most `ui.*` compute is
  natively pinned in `app/jac.toml`; the layout/events frontier stays
  server-pinned with annotated walls. Every pin carries its seal-wall note.
- `ui/demo_live_shell.jac` is the self-contained showcase: a live
  ProcessTerminal shell built only from `ui.*` modules.

Tests live next to code as `<module>.test.jac`; run per-file with
`jac test`, or sweep with `./scripts/jac-test-harness.sh`.

---

## Environment variables

| Variable | Used by | Purpose |
|----------|---------|---------|
| `JAC_TEST_JOBS` | test harness | `0` = serial test runs (recommended) |
| `HOME` | test runtime | point at a disk-backed dir (`.jac-test-home/`) to avoid tmpfs pressure |

---

## Tests

| Suite | Location | Run |
|-------|----------|-----|
| Native jac tests | `app/**/*.test.jac` | `jac test app/<file>.test.jac` (per-file) |
| Constraints oracle | `tests/oracle/test_constraints_oracle.py` | see docstring (needs `kiwisolver`) |
| Vendored compiler | `vendor/jac/jac/tests/` | inside vendor tree |

---

## Human handoff

| Symptom / need | Owner | Notes |
|----------------|-------|-------|
| Native lowering failures in `app/` | jaclang (via `vendor/jac/`) | Fix lands in vendor first, syncs back upstream |

---

## Docs index

| Doc | Contents |
|-----|----------|
| `docs/VENDOR-JAC.md` | Vendored Jac compiler subtree — build, edit, sync, push-back rules |
| `docs/LAYOUT-ENGINE-PLAN.md` | Constraint layout engine design |
| `docs/NATIVE-LOWERING-GAPS-UI-STATE.md` | UI-state lowering gaps |
| `docs/NATIVE-SEAL-FRONTIER.md` | Zero-server-pins seal read (2026-09-15): remaining function seams, root causes, fx reference patterns, port plan |
| `app/ui/README.md` | OSP framework deep dive: invariants, lifetimes, gates |

---

## Practical gotchas

### Native lowering

- Unannotated kwargs and intermediate values block native lowering.
- Placement pins are explicit and deliberate. Don't add pins casually;
  every pin flip must be validated by `jac build` + the sealed artifact
  (`jac test` runs pre-seal and ignores pins).
- In Jac tests, `root` is a built-in reference name; use `tmp_dir` or
  similar instead.

### Working in `app/`

- After editing a `.jac` module, check it compiles/lowers before running
  the dependent test file.
- Toolchain: use the installed release jac at
  `~/.local/share/jac/bin/jac` (symlinked `~/.local/bin/jac`) — a
  self-contained payload built from `vendor/jac` — NOT a stale system jac
  and not the `-Ddev` launcher in `vendor/jac/jac/zig-out/bin` (slow,
  source-linked). Rebuild after vendor edits with
  `cd vendor/jac/jac && zig build -Dskip-precompile -Dpayload-progress`;
  the full precompile needs >9 GB RSS and OOM-kills on a 14 GB box.
