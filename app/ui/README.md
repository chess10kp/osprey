# Osprey OSP UI (`app/ui`)

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
| `cells.jac` | Styled retained cells, SGR attrs, wide-grapheme blit, buffer diff |
| `markdown_proj.jac` | Markdown → styled span lines (projection, not component tree) |
| `terminal.jac` / `virtual_terminal.jac` | Process + in-memory terminal adapters |
| `input.jac` | Byte → semantic event normalization / coalescing / ESC timeout |
| `host.jac` | Process/virtual host tick: poll → decode → coalesce |
| `layout.jac` | Measure/arrange side tables (contracts, rects, clips, scroll clamp) |
| `renderer.jac` | Retained damage, styled cell diff, cursor show/hide, sync ANSI |
| `screen.jac` | Osprey shell topology + editor lifecycle |
| `editor.jac` | Multiline draft, caret, selection, history; `AblePrompt` abilities |
| `transcript.jac` | Visible+overscan virtualization, measure cache, follow-tail, spans |
| `inspect.jac` | Deterministic dumps + invariant validation + leak narratives |
| `markup.jac` | One-time tag → graph lowering — keep thin while authoring is unsettled |
| `gates.jac` | Architecture gates 1–6 |
| `progress_bar.jac` | Gate 5 external widget (also under `widgets/progress/`) |
| `demo_live_shell.jac` | Interactive ProcessTerminal TUI session |

Identity outside the graph is always `jid(node)` / `node_id(n)`.

## Authoring pause

While markup/DSL is unsettled: ship **runtime substrate** (cells, host loop,
layout, transcript projection, protocol→shell, editor, inspect, N1 harness).
Do not grow markup relations/bindings/handlers-in-markup or freeze `list[str]`
as the forever paint DSL — strings remain an interim host convenience that
lowers to styled cells.

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
`explain_invalidation`, `dump_layout`, `dump_damage`, `dump_lifetimes`,
`dump_leak_narrative`) read the semantic graph plus side tables only.

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
JAC_TEST_JOBS=0 jac test ui/cells.jac
JAC_TEST_JOBS=0 jac test ui/markdown_proj.jac
JAC_TEST_JOBS=0 jac test ui/renderer.jac
JAC_TEST_JOBS=0 jac test ui/input.jac
JAC_TEST_JOBS=0 jac test ui/host.jac
JAC_TEST_JOBS=0 jac test ui/editor.jac
JAC_TEST_JOBS=0 jac test ui/gates.jac
# Interactive live TUI (requires a real terminal):
JACPATH=. jac run ui/demo_live_shell.jac
jac check .
```

If pg-embed init fails after a crashed run: `rm -rf ~/.cache/jac/pg/main`
(and prefer a disk-backed `HOME`, not a full `/tmp` tmpfs).

## Gate 4 benchmark

Measured on `run_gate4_invalidation_bench` with header/transcript/status/prompt
content wired (80×24). Re-run to refresh:

```bash
cd app && JACPATH=. jac run -c 'import from ui.gates { run_gate4_invalidation_bench }; print(run_gate4_invalidation_bench())'
```

Assert `retained_cells <= full_frame_cells` and first-frame `cells_written > 0`.

## Gates summary

| Gate | Check |
|------|--------|
| 1 | Detached lifecycle + dispose cleanup |
| 2 | Walker prompt vs callback LOC / advantage |
| 3 | Shell layout, resize, modal overlay, render |
| 4 | Invalidation counters vs full-frame baseline |
| 5 | External `ProgressBar` + markup registration |
| 6 | Dozens of regions via markup, no manual ranks |
