# Jackal OSP UI model

This directory contains the Jackal-local state and structure backend for the
custom terminal UI. It does not replace the differential renderer in
`tui/pi_jac_floor`; it projects into that renderer's existing component
interface.

```text
SignalNode -Feeds-> UiNode -Child(order)-> UiNode
                           |
                           v
                     UiComponent
                  render(width) -> list[str]
                           |
                           v
              flat ANSI differential renderer
```

## Ownership

- `UiNode` and typed edges are the only live application tree.
- `UiRuntime` keeps render, input, and cleanup callables by monotonic node ID.
  Callables are never stored on graph nodes.
- `SignalNode` values use equality cutoff. A write walks only dependent leaves
  and their ancestors to invalidate cached projections.
- A clean `UiComponent.render()` returns the root cache without graph traversal.
  The ANSI renderer still compares flat line arrays and emits terminal updates.
- Focus, overlays, terminal input, and frame scheduling remain in the existing
  TUI renderer for this slice.

## Interface

- `view(render_fn, input_fn, kind, key)` creates a UI node.
- `column(children)` creates an ordered vertical parent.
- `mount`, `move`, and `unmount` mutate typed `Child` edges.
- `signal`, `read_signal`, and `set_signal` provide source reactivity.
- `own_signal` scopes a signal to one subtree.
- `project(root)` returns the existing `render/handleInput/invalidate` shape.
- `compose_layout`, `collect_paint_jobs`, and `paint_frame` (in `paint.jac`)
  assign `screen_row` per node and patch only moved or changed regions.
- `dispose_tree` performs post-order cleanup and removes runtime callbacks.

## Validation

```bash
cd app
JAC_TEST_JOBS=0 jac test ui/model.jac -v
jac check .

cd ..
JACPATH=app:tui/pi_jac_floor jac run scripts/osp-tui-smoke.jac
JACPATH=app:tui/pi_jac_floor jac run scripts/osp-region-smoke.jac
```

`osp-tui-smoke` still exercises the legacy flat diff path via `TUI.doRender()`.
`osp-region-smoke` uses structural region painting and does not need flat-buffer
shift heuristics for the log+spacer case.

## Deliberate limits

This first slice has source signals only. Do not copy Jacket's derived/route
reactive graph until a concrete Jackal UI need requires it. Do not maintain a
parallel `Container.children` tree for migrated Jackal components; replace each
legacy component with one OSP projection as migration proceeds.
