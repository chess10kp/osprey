# Jackal OSP UI (`app/ui`)

Detached, session-local OSP graph for the custom Jac terminal UI (OSPUI.md).
Semantic regions are nodes; containment, focus, feeds, ownership, and layers are
typed edges. Geometry, cells, damage, and cursor state live in process-local
side tables — never on graph nodes and never under Jac's persistent `root`.

## Stable interface

| Module | Role |
|--------|------|
| `model.jac` | `UiNode` archetypes + `Child` / `Owns` / `Feeds` / `FocusNext` / `Layer` |
| `mutation.jac` | Sparse-rank mount/move/detach/replace; atomic validation |
| `runtime.jac` | `UiSession`, focus, overlays, dispose, leak detection |
| `bindings.jac` | Domain source → UI target subscriptions (no cross-lifetime edges) |
| `events.jac` | Typed walkers, target-and-bubble dispatch, effects |
| `width.jac` | ANSI-aware display width, wrap, truncate |
| `terminal.jac` / `virtual_terminal.jac` | Process + in-memory terminal adapters |
| `input.jac` | Byte → semantic event normalization / coalescing |
| `layout.jac` | Measure/arrange side tables (contracts, rects, clips) |
| `renderer.jac` | Retained damage, cell diff, one synchronized ANSI update |
| `screen.jac` | Jackal shell topology + editor / approval lifecycle |
| `transcript.jac` | Visible+overscan virtualization, measure cache, follow-tail |
| `inspect.jac` | Deterministic dumps + invariant validation |
| `markup.jac` | One-time tag → graph lowering (`--print-generated`) |
| `gates.jac` | Architecture gates 1–6 |
| `progress_bar.jac` | Gate 5 external widget (also under `widgets/progress/`) |

Identity outside the graph is always `jid(node)` / `node_id(n)`.

## Lifetimes

1. `create_session()` builds a detached `UiSessionRoot`.
2. Mutations only accept parents reachable from that root.
3. Domain observation uses `bindings.subscribe` — never OSP edges to durable data.
4. `dispose_session()` clears bindings, capabilities, renderer side tables, and the subtree.

Gate 1 asserts no UI jid is reachable from persistent `root`, and that dispose empties registries.

## Invariants

`validate_invariants(session)` / `validate_session(session)` report:

- orphan bindings, invalid focus, unreleased capabilities
- stale edges / renderer layout keys
- containment cycles, duplicate sibling keys, non-increasing ranks

Inspection dumps (`dump_graph`, `dump_bindings`, `dump_event_path`,
`explain_invalidation`, `dump_layout`, `dump_damage`, `dump_lifetimes`) read the
semantic graph plus side tables only.

## Migration rules

- Do not store dirty/cached/painted/geometry on nodes.
- Do not create OSP nodes for transcript lines or terminal cells.
- Do not attach UI nodes to persistent `root`.
- Prefer markup or direct construction once; mutate topology for conditionals.
- Retire legacy `paint.jac` callers — use `render_frame`.
- External widgets register via `register_tag` / `register_progress_markup`
  without editing framework source.

## Validation

```bash
cd app
export HOME="${HOME:-$PWD}/.jac-test-home"   # avoid /tmp tmpfs pressure
JAC_TEST_JOBS=0 jac test ui/model.jac
JAC_TEST_JOBS=0 jac test ui/transcript.jac
JAC_TEST_JOBS=0 jac test ui/inspect.jac
JAC_TEST_JOBS=0 jac test ui/markup.jac
JAC_TEST_JOBS=0 jac test ui/gates.jac
jac check .

# Individual gates (same module):
JACPATH=app jac run - <<'EOF'   # or import run_gateN from ui.gates in a .jac file
EOF
```

If pg-embed init fails after a crashed run: `rm -rf ~/.cache/jac/pg/main`
(and prefer a disk-backed `HOME`, not a full `/tmp` tmpfs).

## Gate 4 benchmark (recorded)

Measured on the Unit 13 harness (`run_gate4_invalidation_bench`), 80×24
virtual terminal, shell insert + two retained frames:

| Metric | Value |
|--------|------:|
| `nodes_queried` | 6 |
| `cells_written` (sum) | 0* |
| `latency_ms` | ~2.5 |
| `full_frame_cells` | 1920 |
| `retained_cells` | 0* |

\*Empty content contracts produce zero cell writes in this minimal shell paint;
the important assertion is `retained_cells <= full_frame_cells`. Re-run the
harness after wiring transcript/status content to refresh these numbers.

## Gates summary

| Gate | Check |
|------|--------|
| 1 | Detached lifecycle + dispose cleanup |
| 2 | Walker prompt vs callback LOC / advantage |
| 3 | Shell layout, resize, modal overlay, render |
| 4 | Invalidation counters vs full-frame baseline |
| 5 | External `ProgressBar` + markup registration |
| 6 | Dozens of regions via markup, no manual ranks |
