# Osprey

**A retained, semantic terminal UI framework for Jac (OSP).**

Semantic regions are graph nodes; containment, focus, feeds, ownership, and
layers are typed edges. Geometry, cells, damage, and cursor state live in
process-local side tables. Ships a constraint-based layout engine, a
damage-tracked renderer, terminal/virtual-terminal hosts, an input
normalizer, markdown projection, and an editor + transcript stack.

## Quick start

```bash
cd app
jac run ui/demo_live_shell.jac   # interactive demo (needs a real TTY)
jac build                        # native compile check
jac test ui/<module>.test.jac    # per-file unit tests
```

Requires the `jac` CLI on PATH. The vendored compiler under `vendor/jac/`
is the source of truth for native lowering — see
[`docs/VENDOR-JAC.md`](docs/VENDOR-JAC.md).

## Layout

| Path | Role |
|------|------|
| `app/ui/` | OSP framework: model/mutation/bindings/events, terminals, renderer, editor, transcript, layout, markup, focus, gates, widgets |
| `app/constraints/` | Constraint layout solver (algebra, relations, solver, oracle) |
| `app/cordis/` | Composition core: revertible effects + reactive coeffects |
| `app/core/` | Edit/diff kernel |
| `tests/oracle/` | Kiwi differential oracle for the constraint solver |
| `scripts/` | Test harness + vendored-compiler setup |
| `docs/` | Design and lowering docs |

### Acknowledgements

- [Pi](https://pi.dev): For inspiring the TUI implementation
