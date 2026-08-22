# Plan: Constraint-Based Terminal Layout Engine

> **Status:** Reviewed and implementation-ready — not started.
> **Scope:** `app/` TUI only.
> **Related:** [`ROADMAP.md`](../ROADMAP.md) N1/N2,
> [`OSPUI-P0-PLAN.md`](./OSPUI-P0-PLAN.md), `docs/decisions.org`, and the current
> [`app/ui/layout.jac`](../app/ui/layout.jac).

---

## 1. Review outcome and binding decision

Replace the current hand-written measure/arrange implementation in
`app/ui/layout.jac` with a pure-Jac constraint solver and a terminal-specific layout
module. Keep the public layout seam small and keep all geometry in renderer-owned side
tables keyed by `jid(node)`.

The reviewed decisions are binding:

| Concern | Decision |
|---|---|
| Product location | Implement under the existing `app/` Jac project. Do not create sibling projects or local-package shims. |
| Placement | Keep the complete UI layout path **server-pinned**. `ui.model` is OSP-based and `ui.width` imports Python `unicodedata`; moving `ui.layout` to native would contradict the verified placement design. |
| Solver | Pure Jac, data-oriented Cassowary-style incremental simplex. No OSP nodes/edges in the tableau. |
| Native work | None in this plan. Profile the landed server implementation first. A later native kernel requires a separate measured design. |
| External dependency | `kiwisolver` is a test-only differential oracle provisioned by the oracle CI job. It is not an application dependency. |
| Layout declarations | Process-local `LayoutSpec` and `LayoutRelation` values in the layout registry. OSP `Child` and `Layer` edges supply topology; do not add geometry relations to the semantic graph. |
| Strengths | Symbolic lexicographic objectives. Do not approximate tiers with undocumented scalar weights. |
| Grow | Deterministic bounded proportional allocation before constraint emission. Grow weights are not Cassowary strengths. |
| Text measurement | Axis-separated pipeline: solve width, quantize width, measure/wrap text once, then solve height. Cross-axis equations are rejected. |
| Scroll | View transform outside the solver. |
| Migration | Test-only dual execution, one product cutover, then delete the old implementation. No runtime fallback flag. |
| Framework/compiler gaps | Stop and hand off to the human. Do not vendor, patch Jac, add C/Python production shims, or rely on compiler fallback. |

This supersedes the earlier proposal to create `packages/jac-constraints`, create
`packages/jac-layout`, compile the full layout path to native, or use a C-ABI fallback.
Those choices conflict with `AGENTS.md`, `ROADMAP.md`, `app/jac.toml`, and the verified
native-lowering findings in `OSPUI-P0-PLAN.md`.

---

## 2. Ground truth and success criteria

### 2.1 Current behavior that must survive

The current `app/ui/layout.jac` owns:

- `Rect`, `Size`, contracts, measured size, current/previous rect, clip, scroll state,
  wrapped lines, and dirtiness in `LayoutTables`, keyed by `node_id`/`jid`;
- bottom-up intrinsic measurement using `ui.width.wrap_text`;
- top-down vertical and horizontal flow over ordered `Child` edges;
- fixed, intrinsic, bounded, grow, child-viewport, and overlay behavior;
- overlay ordering from `Layer(z_index, modal)` edges;
- clipping, scroll clamping, and old/new rectangle snapshots for renderer damage.

Known consumers that must be migrated deliberately:

- `app/ui/renderer.jac` and `app/ui/renderer.test.jac`
- `app/ui/gates.jac`
- `app/ui/screen.jac` and `app/ui/screen.test.jac`
- `app/ui/demo_complex_shell.jac` and its test
- `app/ui/demo_live_shell.jac`
- `app/ui/n1_acceptance.jac`
- `app/ui/layout.test.jac`

Search again for `set_contract`, `LayoutContract`, `measure_and_arrange`, and
`rect_of` immediately before the cutover. The list above is a baseline, not permission
to ignore new consumers.

### 2.2 Definition of success

The work is complete only when:

1. the solver satisfies its algebraic, incremental, atomicity, determinism, and oracle
   tests;
2. the new layout module reproduces required terminal behavior for flow, wrapping,
   clipping, scrolling, overlays, resize, and degenerate viewports;
3. renderer output remains correct, including desired cells, cursor state, damage, and
   patch scope—not only rectangles;
4. all product callers use the new permanent interface;
5. no production legacy path, compatibility flag, vendored package, native fallback,
   or foreign-language solver remains; and
6. the old measure/arrange implementation and migration-only oracle are deleted.

Rollback after cutover is source-control rollback, not a second runtime engine.

---

## 3. Target module map and dependency direction

Use the existing `app/jac.toml` project:

```text
app/
├── constraints/
│   ├── algebra.jac          # Variable, expression, relation, strength, normalization
│   ├── results.jac          # Handles, snapshots, typed solver outcomes
│   ├── solver.jac           # Incremental tableau, objective, edits, rollback journal
│   ├── solver.test.jac
│   └── oracle_driver.jac    # JSONL batch driver; no Kiwi import
└── ui/
    ├── layout.jac           # Permanent public seam + orchestration
    ├── layout_compile.jac   # Child/Layer topology + registry -> constraints
    ├── layout_measure.jac   # Natural width and wrapped-height measurement/cache
    ├── layout_quantize.jac  # Solved floats -> coherent terminal-cell edges
    ├── layout_validate.jac  # Scope, topology, spec, frame, provenance validation
    ├── layout.test.jac
    └── testing/
        └── legacy_layout_oracle.jac  # Migration only; deleted at cutover
```

Dependency direction:

```text
constraints.*
    ↑
ui.layout_compile / ui.layout_quantize / ui.layout_validate
    ↑
ui.layout
    ↑
ui.renderer and ui.screen
```

Rules:

- `constraints.*` imports no `ui.*`, OSP type, Python module, terminal code, or app
  domain type.
- `ui.layout` may import `ui.model`, `ui.width`, and `constraints.*`.
- `ui.renderer` depends only on the public names defined by `ui.layout`; it must not
  import layout internals or solver types.
- Semantic `UiNode` objects remain free of geometry, constraints, caches, and dirty
  flags.
- Add explicit server placement pins for each new `constraints.*` and `ui.layout_*`
  module. Do not depend on implicit native-to-server fallback.
- Reusable package extraction is a future repository decision after the interface is
  stable. It is not part of implementation or cutover.

The deletion test for this module is intentional: deleting `ui.layout` would force
constraint compilation, measurement, quantization, validation, and failure handling
into every renderer caller. The module therefore earns its seam.

---

## 4. Permanent layout interface

`ui.layout` is the external seam used by the renderer, screen configuration, and tests.
Use these public shapes; only spelling changes required by the Jac compiler are allowed.

```jac
enum LayoutSeverity { WARNING, ERROR }
enum LayoutError {
    INVALID_SPEC,
    INVALID_RELATION,
    STALE_NODE,
    OUT_OF_SCOPE,
    INVALID_TOPOLOGY,
    UNSATISFIABLE,
    OVERFLOW,
    UNSUPPORTED_AXIS_COUPLING,
    INTERNAL_INVARIANT
}

obj Viewport { has columns: int, rows: int; }
obj RelationHandle { has id: int; }
obj LayoutDiagnostic {
    has code: LayoutError,
        severity: LayoutSeverity,
        message: str,
        node_ids: list[str] = [],
        provenance: list[str] = [];
}
obj FrameEntry {
    has measured: Size,
        rect: Rect,
        clip: Rect,
        wrapped_lines: list[str],
        requested_scroll_offset: int = 0,
        scroll_offset: int = 0,
        max_scroll_offset: int = 0;
}
obj LayoutFrame {
    has generation: int,
        viewport: Viewport,
        entries: dict[str, FrameEntry],
        overlay_ids: list[str];
}
obj MutationResult {
    has ok: bool,
        relation_handle: RelationHandle | None = None,
        diagnostics: list[LayoutDiagnostic] = [];
}
obj LayoutResult {
    has ok: bool,
        frame: LayoutFrame | None = None,
        diagnostics: list[LayoutDiagnostic] = [];
}
obj LayoutState;  # Registry, measurement cache, solver state, next IDs, last frame.

# Registration and invalidation.
def create_layout_state(columns: int = 80, rows: int = 24) -> LayoutState;
def set_spec(state: LayoutState, node: UiNode, spec: LayoutSpec) -> MutationResult;
def add_relation(state: LayoutState, relation: LayoutRelation) -> MutationResult;
def remove_relation(state: LayoutState, handle: RelationHandle) -> MutationResult;
def set_content(
    state: LayoutState,
    node: UiNode,
    lines: list[str],
    content_revision: int,
    style_revision: int = 0,
) -> MutationResult;
def clear_node(state: LayoutState, node: UiNode) -> MutationResult;
def set_scroll_offset(
    state: LayoutState,
    node: UiNode,
    offset: int,
) -> MutationResult;

# One transaction: validate -> solve width -> measure -> solve height -> quantize.
def compute_layout(
    state: LayoutState,
    layout_root: UiNode,
    viewport: Viewport,
) -> LayoutResult;

# Copy one entry/rect from the last successfully published frame.
def rect_of(state: LayoutState, node: UiNode) -> Rect;
def frame_entry_of(state: LayoutState, node: UiNode) -> FrameEntry | None;
```

Interface invariants:

1. `compute_layout` builds into scratch state and publishes one complete frame only on
   success. An error result has `ok=False`, `frame=None`, at least one `ERROR`
   diagnostic, and leaves the prior published frame unchanged. A successful clipped
   frame may include `WARNING` diagnostics such as `OVERFLOW`.
2. Frames are immutable by ownership convention: after construction, no code mutates a
   frame or any nested list/map/value. Publication replaces the frame reference;
   `rect_of` and `frame_entry_of` return deep copies. Tests hash a frame before and after
   later layouts to enforce snapshot isolation despite Jac `obj` mutability.
3. `LayoutFrame.generation` is a state-local monotonic integer incremented only on
   successful publication. The renderer retains its prior and current frame references
   and computes damage from them. Layout owns no `prev_rect` or damage snapshot; the
   renderer must not reconstruct measurement, clip, wrap, scroll, or overlay order.
4. A failed operation returns diagnostics with provenance and never invokes the legacy
   engine.
5. `clear_node` removes registry specs, content, measurement cache entries, and every
   relation for which the node is owner, source, or target. The last published frame is
   unchanged until the next successful `compute_layout`; the next frame omits the node,
   allowing renderer-owned frame differencing to damage its old rect.
6. Content cache identity is `(node_id, content_revision, integer_width, style_revision)`.
   Revisions cannot decrease for one node. A caller must advance the applicable revision
   when text or width-affecting style changes.
7. `LayoutFrame` is complete for its generation: it contains every live laid-out node
   and ordered overlay, or publication fails.
8. The root viewport is an input to `compute_layout`, not a `LayoutSpec` installed by
   every caller.
9. Screen layout ownership is explicit: `ui.screen` defines
   `configure_main_shell_layout(state, shell)`. Every bootstrap/demo calls it once after
   `build_main_shell`. Product geometry must not be scattered across demos and gates.

### 4.1 Replace the overloaded legacy contract

Do not carry `LayoutKind` into the permanent interface. It conflates four independent
concerns: container flow, axis sizing, scrolling, and overlay participation.

Use separate values:

```jac
enum Axis { HORIZONTAL, VERTICAL }
enum SizeMode { FIXED, INTRINSIC, BOUNDED, FILL, GROW }
enum Align { START, CENTER, END, STRETCH }
enum OverlayAnchor { CENTER, TOP, BOTTOM, LEFT, RIGHT }

obj AxisSize {
    has mode: SizeMode,
        minimum: float = 0.0,
        preferred: float | None = None,
        maximum: float | None = None,
        grow_weight: float = 0.0;
}

obj LayoutSpec {
    has flow_axis: Axis = Axis.VERTICAL,
        width: AxisSize,
        height: AxisSize,
        cross_align: Align = Align.STRETCH,
        scroll_vertical: bool = False,
        overlay_anchor: OverlayAnchor | None = None;
}
```

Validation rejects negative bounds, `minimum > maximum`, non-finite values, non-positive
`GROW` weights, overlay anchors on nodes not reached through `Layer`, and unsupported
cross-axis relations.

Relations are process-local renderer data—not OSP edges:

```jac
enum LayoutRelationKind {
    LEFT_OF, RIGHT_OF, ABOVE, BELOW,
    ALIGN_START, ALIGN_END, ALIGN_CENTER, SAME_SIZE
}
obj LayoutRelation {
    has owner_id: str,       # direct parent that owns the declaration
        source_id: str,
        target_id: str,
        kind: LayoutRelationKind,
        axis: Axis,
        gap: float = 0.0,
        strength: StrengthTier = StrengthTier.REQUIRED,
        provenance: str;
}
```

For the first implementation, owner must be the direct `Child` parent of both endpoints.
A replacement node receives a new `jid` and does not inherit relations. `clear_node`
removes all incident and owned relations atomically. Directional gaps must be finite and
non-negative; alignment/size relations require `gap == 0`. `LEFT_OF`/`RIGHT_OF` require
`HORIZONTAL`; `ABOVE`/`BELOW` require `VERTICAL`.

Exact equations (`L`, `R`, `T`, `B` mean source edges; subscript `t` means target):

| Relation | Equation |
|---|---|
| `LEFT_OF` | `R + gap == L_t` |
| `RIGHT_OF` | `L == R_t + gap` |
| `ABOVE` | `B + gap == T_t` |
| `BELOW` | `T == B_t + gap` |
| `ALIGN_START`, horizontal | `L == L_t` |
| `ALIGN_START`, vertical | `T == T_t` |
| `ALIGN_END`, horizontal | `R == R_t` |
| `ALIGN_END`, vertical | `B == B_t` |
| `ALIGN_CENTER`, horizontal | `L + R == L_t + R_t` |
| `ALIGN_CENTER`, vertical | `T + B == T_t + B_t` |
| `SAME_SIZE`, horizontal | `R - L == R_t - L_t` |
| `SAME_SIZE`, vertical | `B - T == B_t - T_t` |

Canonicalize generated and explicit equations before insertion. Merge provenance for an
exact duplicate with the same relation and strength; reject a duplicate expression with
a different strength as `INVALID_RELATION`. Potentially conflicting non-duplicate
required equations proceed to the solver and report `UNSATISFIABLE` with all provenance.
Do not add aspect ratio or any equation that mixes horizontal and vertical variables.

---

## 5. Generic constraint solver

### 5.1 Core values

```jac
enum Relation { LEQ, EQ, GEQ }
enum SymbolKind { INVALID, EXTERNAL, SLACK, ERROR, DUMMY }
enum StrengthTier { REQUIRED, STRONG, MEDIUM, WEAK }

obj Variable { has id: int; }
obj Term { has variable: Variable, coefficient: float; }
obj Expression { has terms: list[Term], constant: float; }
obj Constraint {
    has expression: Expression,
        relation: Relation,
        strength: StrengthTier;
}
obj ConstraintHandle { has id: int; }
obj Row { has constant: float, cells: dict[int, float]; }
obj LexWeight { has strong: float, medium: float, weak: float; }
obj SolverSnapshot {
    has generation: int,
        values: dict[int, float],       # variable id -> value
        objective: LexWeight;
}
```

Variables and constraint handles are allocated by one `Solver`; callers do not choose
IDs. A handle belongs to exactly one solver.

### 5.2 Solver interface

```jac
obj SolverResult {
    has ok: bool,
        error: SolveError = SolveError.OK,
        handle: ConstraintHandle | None = None,
        message: str = "",
        witness_handles: list[ConstraintHandle] = [];
}
obj Solver {
    def new_variable() -> Variable;
    def add_constraint(c: Constraint) -> SolverResult;  # returns handle
    def remove_constraint(handle: ConstraintHandle) -> SolverResult;
    def add_edit_variable(v: Variable, strength: StrengthTier) -> SolverResult;
    def remove_edit_variable(v: Variable) -> SolverResult;
    def suggest_value(v: Variable, value: float) -> SolverResult;
    def values() -> SolverSnapshot;
    def has_constraint(handle: ConstraintHandle) -> bool;
    def reset();
}
```

Keep expression construction helpers in `constraints.algebra`; do not expand `Solver`
with one method per algebra operation.

### 5.3 State and strength semantics

The tableau state is:

```text
rows             dict[int, Row]              basic symbol -> scalar row
variables        dict[int, int]              variable id -> external symbol
constraints      dict[int, Tag]              handle -> marker/error symbols
objective        dict[int, LexWeight]        symbol -> symbolic tier coefficient
infeasible_rows  list[int]                   dual-optimize worklist
edits            dict[int, EditInfo]          variable id -> edit metadata
next IDs         deterministic monotonic integers
```

`REQUIRED` constraints participate in feasibility and never enter the objective.
Non-required errors use `LexWeight(strong, medium, weak)`. Addition and scalar
multiplication are component-wise; sign and ordering compare the first component whose
absolute difference exceeds epsilon. This provides actual lexicographic tiers. Do not
replace it with `1e6/1e3/1` scalar weights.

Numeric policy:

- reject NaN and infinity at the interface;
- use one named `EPSILON = 1e-8` for zero tests and feasibility comparisons;
- normalize every expression by combining duplicate variables, dropping coefficients
  within epsilon of zero, and ordering terms by variable ID;
- use deterministic minimum-symbol-ID tie-breaking after the required ratio comparison;
- never depend on `dict` iteration order; and
- use scalar float rows only. Objective weights are vectors, not tableau coefficients.

### 5.4 Atomicity and errors

Normal outcomes are typed results, not exceptions:

```jac
enum SolveError {
    OK,
    UNSATISFIABLE,
    DUPLICATE_CONSTRAINT,
    UNKNOWN_CONSTRAINT,
    FOREIGN_HANDLE,
    DUPLICATE_EDIT_VARIABLE,
    UNKNOWN_EDIT_VARIABLE,
    REQUIRED_EDIT_VARIABLE,
    NON_FINITE_VALUE,
    INVALID_EXPRESSION,
    INTERNAL_INVARIANT
}
```

All mutating operations are atomic. Use an internal mutation journal and reverse it on
failure; do not leave marker rows, error symbols, objective terms, or advanced IDs from
a failed operation. Programmer invariant failures may raise after attaching a tableau
dump, but must never be reported as `UNSATISFIABLE`.

`SolverSnapshot.generation` increments on each successful solver mutation, including an
edit suggestion, and does not increment on failure. `values()` returns a deep-copied
snapshot and never exposes mutable solver rows, tags, or objective storage. A failed
result has `ok=False`, a non-`OK` error, no handle, and an unchanged generation. A
successful `add_constraint` is the only operation that returns a new handle.

---

## 6. Layout compilation semantics

Each live node gets four external variables: left, top, right, bottom. Width and height
are derived expressions (`right - left`, `bottom - top`), not separately mutable facts.
Every node has required `right >= left` and `bottom >= top` constraints.

All generated constraints carry provenance:

```text
node jid + node key
source LayoutSpec or LayoutRelation handle
Child/Layer parent jid and rank/z-index when relevant
axis and generated-template name
```

The layout compiler validates one detached `Child` tree rooted at `layout_root` plus
`Layer` overlays owned by that root screen. A relation may reference only nodes in that
scope. Reject cycles, multiple `Child` parents, duplicate node IDs, missing specs,
stale relation targets, and duplicate/equal `Layer` ordering without a deterministic
secondary key.

### 6.1 Legacy behavior mapping

The migration is semantic, not a one-for-one `LayoutKind` port:

| Current behavior | Permanent representation | Generated behavior |
|---|---|---|
| Root viewport | `compute_layout(..., Viewport)` input | Required root edges `(0, 0, columns, rows)`; columns/rows are edit values on resize. |
| `FIXED` | `AxisSize(FIXED, preferred=n)` | Required axis size equals `n`. An unspecified legacy axis maps independently, not to zero. |
| `INTRINSIC` | `AxisSize(INTRINSIC)` | Required non-negative bounds; weak preference for measured natural size. |
| `BOUNDED` | `AxisSize(BOUNDED, min, preferred, max)` | Required min/max; weak preferred equality when present. |
| `GROW(weight)` | `AxisSize(GROW, grow_weight=weight)` | Bounded proportional allocator produces deterministic continuous target sizes; compiler emits exact continuous partition equalities. Cell quantization follows §7.2. |
| Child `VIEWPORT` | Usually `height=GROW`, `width=FILL`, `scroll_vertical=True` | Fills the assigned parent slot and keeps full wrapped content for scroll. It does **not** reset position to `(0,0)`. |
| `OVERLAY(w,h)` | Node reached through `Layer` plus fixed/bounded axis sizes and `overlay_anchor` | Out of normal flow, deterministically ordered, anchored within root, clipped when the terminal is smaller. |
| Horizontal container | `flow_axis=HORIZONTAL` | Ordered `Child` siblings partition the parent horizontal content span. |
| Vertical container | `flow_axis=VERTICAL` | Ordered `Child` siblings partition the parent vertical content span. |

### 6.2 Grow allocation—decided before solver integration

Grow is a flow policy, not a strength tier. For each sibling partition:

1. Validate every grow weight is finite and strictly positive.
2. Subtract fixed/intrinsic/bounded non-grow claims from the parent span.
3. If the remainder is negative, assign non-grow nodes according to required minimums,
   clip through the normal parent clip, and attach an `OVERFLOW` warning to the otherwise
   successful frame. Never create negative child sizes.
4. Allocate the non-negative remainder proportionally among unfrozen grow children.
5. If a target violates a required minimum or maximum, freeze that child at the bound,
   subtract it, and repeat over the remaining children.
6. Emit the resulting floating target sizes as required equalities for the continuous
   solve.
7. Quantize the complete sibling partition with the largest-remainder rule in §7.2.

The continuous equality is not reasserted on integer cells. The terminal-frame contract
replaces it with exact integer partition closure and a per-child rounding residual below
one cell. Zero or negative weights are errors; do not reinterpret them as `1.0`.

### 6.3 Overlay semantics

- `Layer.z_index` orders paint ascending and hit/input selection descending.
- Equal `z_index` values break ties by stable overlay `jid`; tests lock this behavior.
- `Layer.modal` remains input/focus policy and is not a solver constraint.
- Centering uses the root content box. A fixed overlay larger than the terminal keeps
  its requested size but receives a root-bounded clip; origin is clamped to `(0,0)`.
- Bounded overlays shrink only when their declared minimum/maximum permits it.
- Closing or removing an overlay makes the next frame omit its entry; renderer-owned
  frame differencing damages the previous rect.

---

## 7. Width-dependent measurement and quantization

### 7.1 Axis-separated measurement—no convergence loop

Terminal text height depends on integer width. Keep this non-linear operation outside the
linear solver and prohibit axis coupling:

1. **Natural-width measurement:** measure unwrapped content width and width-independent
   bounds from `ui.width`.
2. **Horizontal solve:** compile and solve only left/right constraints.
3. **Horizontal quantization:** publish no state yet; quantize horizontal edges to cells.
4. **Wrapped-height measurement:** wrap content exactly once at each quantized width and
   cache by `(node_id, content_revision, width, style_revision)`.
5. **Vertical solve:** compile top/bottom constraints using measured heights as constants.
6. **Vertical quantization and validation:** quantize, derive clips/scroll bounds, and
   validate the complete frame.
7. **Atomic publish:** replace the prior frame only after all phases succeed.

Vertical results must never feed horizontal constraints. A relation that mixes axes or
an aspect-ratio request returns `UNSUPPORTED_AXIS_COUPLING`. This rule gives a fixed
single pass and removes oscillation, stale remeasure, and arbitrary iteration limits.

### 7.2 Cell quantization—locked policy

Independent rounding of `x` and `width` can create gaps and overlap. Quantize edges:

- viewport edges are exact integers;
- values within `EPSILON` of an integer snap to that integer;
- other unconstrained edges round to nearest integer, with exact halves toward the
  smaller coordinate;
- required-equal edge expressions are grouped and snapped once for the group;
- flow partitions use largest remainder: floor each flexible child's continuous target,
  then distribute the remaining cells one each by descending fractional remainder, with
  ordered `Child.rank` and then `jid` as ties; fixed integer claims remain fixed;
- for a bounded flexible child, integer validation uses `ceil(minimum)` and
  `floor(maximum)`; reject a bound interval containing no integer cell size;
- after partition quantization, every flexible child differs from its continuous target
  by less than one cell and child sizes sum exactly to the integer parent span;
- derive `width = right_cell - left_cell` and
  `height = bottom_cell - top_cell`; never round size independently;
- reject negative derived sizes as an internal invariant failure;
- compute clips only after quantization; and
- center overlays with integer floor division to preserve current terminal behavior.

Frame validation asserts root bounds, non-negative dimensions, required adjacency,
partition closure, declared min/max after allowed clipping, deterministic overlay order,
and clips contained by their parent clips.

### 7.3 Scroll

Scroll offset is a post-layout view transform. After wrapping and quantization:

```text
max_offset = max(0, wrapped_line_count - visible_height)
clamped_offset = min(max(requested_offset, 0), max_offset)
```

A resize reclamps from the requested offset. The solver never receives scroll variables.

---

## 8. Verification strategy

### 8.1 Solver tests

Unit tests cover:

- expression normalization and finite-value rejection;
- required equality/inequality systems;
- unsatisfiable required constraints;
- symbolic strong/medium/weak ordering;
- deterministic pivot ties and underdetermined systems;
- add/remove sequences;
- edit-variable suggestions and dual optimization;
- foreign/unknown handles and duplicate edit variables;
- failed-operation rollback, including exact pre/post tableau dumps; and
- reset and snapshot isolation.

Property generators use seeded systems of 1–20 variables and 1–50 constraints, including
random add/remove and edit sequences. Every minimized failure becomes a committed fixed
fixture.

### 8.2 Kiwi differential oracle

Use a separate Python oracle harness; Jac production/test modules never import Kiwi:

```text
tests/oracle/test_constraints_oracle.py  # stdlib unittest + kiwisolver
app/constraints/oracle_driver.jac        # batched JSONL stdin/stdout -> Solver
```

The Python harness generates seeded operation batches, evaluates them with Kiwi, sends
the same batches to one `jac run constraints/oracle_driver.jac` subprocess with
`cwd=app`, and compares normalized JSON responses. The driver imports only
`constraints.*`; it does not import Python or Kiwi. JSON includes schema version, seed,
variables, constraints, ordered operations, snapshots, residuals, objective vector, and
error code. Unknown schema versions fail before execution.

Exact local/CI command:

```bash
python3 -m venv .venv-layout-oracle
.venv-layout-oracle/bin/python -m pip install 'kiwisolver==1.5.0'
.venv-layout-oracle/bin/python tests/oracle/test_constraints_oracle.py \
  --jac "$(command -v jac)"
```

The script uses `unittest` from the standard library, exits non-zero on disagreement,
and prints the seed plus a minimized JSON fixture. CI caches or recreates the virtual
environment outside application packaging. Do not add `kiwisolver` to `app/jac.toml`
runtime dependencies.

Compare:

1. satisfiable vs unsatisfiable required systems;
2. variable values only for fixtures proven uniquely determined;
3. required-constraint residuals for underdetermined systems;
4. lexicographic objective violation vectors for soft systems;
5. add/remove/edit sequence invariants and failure classes; and
6. exact expected values for deliberate deterministic tie fixtures.

Use relative/absolute tolerance for float values. Do not require arbitrary external
variable values to equal Kiwi in underdetermined systems. Our symbolic lexicographic
objective may intentionally differ from Kiwi's finite scalar encoding on pathological
large-error cases; such cases assert our documented tier semantics rather than Kiwi
identity.

### 8.3 Layout parity and renderer acceptance

Before product cutover, `ui.testing.legacy_layout_oracle` contains the frozen old
measure/arrange implementation. Tests run old and new engines over the same graph and
compare:

- measured sizes, rects, clips, and wrapped lines;
- clamped scroll offsets and visible content;
- overlay order and bounds;
- desired plain/styled cell buffers;
- cursor row/column/visibility;
- damage rectangles and patch cell count after grow, shrink, move, resize, overlay
  close, and node removal; and
- absence of stale entries after disposal.

Strict equality is required after quantization except for one approved correction:
partitions with three or more fractional grow targets use largest remainder instead of
biasing every leftover cell to the final child. The regression test asserts exact
partition closure, less-than-one-cell residual per grow child, and rank/`jid` tie-breaks.
No other parity difference is pre-approved. A full clear must not hide damage bugs.

Test viewport matrix at minimum:

```text
0x0, 1x1, 2x1, 8x3, 40x12, 80x24, 200x60
```

Content matrix includes empty text, ASCII, ANSI, combining marks, CJK, emoji, multiline
text, content wider than the viewport, and content taller than a scrolling child.

### 8.4 Determinism and performance

- Same seeded input in fresh processes must produce the same symbol allocation trace,
  constraint handles, diagnostics, and quantized frame.
- Float values compare within tolerance; do not demand byte identity across unrelated
  targets.
- Record server benchmarks for cold full solve and warm resize/edit on a representative
  shell of about 80 nodes/300 constraints.
- Gate target: p95 `compute_layout` below 5 ms after warm-up on the documented developer
  machine, and no unbounded per-frame growth in rows, symbols, relations, or cache
  entries.
- If the target fails, profile before changing placement or data structures. Native or
  foreign kernels require a separate human-approved design.

---

## 9. Milestones and commit sequence

Each milestone is one feature/bugfix commit unless it must be split to keep every commit
compiling. Start from a clean worktree. Do not mix unrelated `app/` work into these
commits.

### M0 — Policy and feasibility gate

Implement the smallest server-placed solver slice:

```text
a = 0
b = a + 10
c = b + 20
=> a=0, b=10, c=30
```

Exit criteria:

- module imports work inside the existing `app/` project with explicit server pins;
- finite float and sparse `dict[int, float]` row operations work without compiler
  fallback;
- one equality system solves deterministically;
- `kiwisolver` can be imported only in the oracle test job;
- baseline row-operation and one-shot timings are recorded; and
- `docs/decisions.org` records the server-first pure-Jac solver, symbolic strengths,
  axis separation, test-only Kiwi oracle, and no-workaround stop rule.

Stop if any compiler/package requirement cannot be met directly. File a human handoff;
do not vendor or shim.

### M1 — Static required solver

- Algebra normalization and construction helpers.
- Required equalities and inequalities with slack/dummy symbols.
- Subject selection, pivoting, artificial-variable feasibility.
- Typed handles/results, deterministic ordering, provenance hooks.
- Atomic add and exact rollback on failure.
- Required-system unit/property/oracle tests.

### M2 — Constraint hierarchy

- Symbolic `LexWeight` objective.
- Error symbols for strong/medium/weak constraints.
- Primal optimization and deterministic ties.
- Soft-system objective/residual tests against documented semantics and Kiwi's shared
  domain.

Do not begin layout parity work before M2 is green and the quantization tests in M4 are
specified.

### M3 — Incrementality

- Constraint removal.
- Edit variables, suggestions, infeasible-row worklist, and dual optimization.
- Resize/edit sequence oracle tests.
- Leak tests proving row/symbol/objective state returns to baseline after add/remove
  cycles.
- Rebuild-vs-incremental shell benchmark.

Incremental APIs are completeness requirements even if full rebuild is already fast.
Optimization effort beyond correctness follows benchmark evidence.

### M4 — Layout types, registry, compiler, and quantizer

- Permanent `LayoutSpec`, `AxisSize`, `LayoutRelation`, result, diagnostic, and frame
  values in `ui.layout`.
- Registry lifecycle and stale-reference validation.
- Root, fixed, intrinsic, bounded, fill, flow, bounded-grow, and overlay templates.
- Provenance on every generated constraint.
- Locked edge quantization and frame invariant tests.
- `configure_main_shell_layout(state, shell)` in `ui.screen`; no caller migration yet.

### M5 — Measurement and complete engine

- Natural-width and wrapped-height measurement/cache.
- Horizontal solve -> width quantization -> wrap -> vertical solve.
- Clip propagation, scroll clamping, overlay arrangement, and atomic frame publication.
- Degenerate viewport and overflow diagnostics.
- Test-only dual-run fixture and full parity corpus.
- Representative shell benchmark.

The product renderer still uses the old path during this milestone. The new engine is
reachable only from tests; this is not a runtime feature flag.

### M6 — Atomic product cutover and hard removal

In one reviewable sequence:

1. migrate `renderer`, `screen` bootstraps, gates, demos, acceptance, and tests to the
   permanent interface;
2. replace scattered shell contract setup with `configure_main_shell_layout`;
3. make renderer consume complete `LayoutFrame` data;
4. run the strict parity, renderer, demo, N1 acceptance, full app, oracle, and benchmark
   gates;
5. obtain human approval of the cutover checklist;
6. delete `LayoutKind`, `LayoutContract`, `set_contract`, old
   `measure_and_arrange`, migration adapters, production dual-run code if any was
   accidentally introduced, and `ui/testing/legacy_layout_oracle.jac`; and
7. grep for all removed names and confirm zero product matches.

Do **not** change `"ui.layout" = "server"` to native. Keep explicit server pins for the
whole layout module set.

---

## 10. Cutover checklist

All items are falsifiable and required:

- [ ] `cd app && jac check .` succeeds without placement fallback notes.
- [ ] `JAC_TEST_JOBS=0 jac test constraints/solver.test.jac` passes.
- [ ] The pinned Kiwi oracle job passes.
- [ ] `JAC_TEST_JOBS=0 jac test ui/layout.test.jac` passes.
- [ ] `JAC_TEST_JOBS=0 jac test ui/renderer.test.jac` passes, including patch-scope
      limits.
- [ ] Screen, complex demo, live demo, gates, and `n1_acceptance` tests pass.
- [ ] `JAC_TEST_JOBS=0 jac test .` passes.
- [ ] Viewport/content matrices in §8.3 pass.
- [ ] Determinism reruns produce identical quantized frames and diagnostics.
- [ ] p95 warm layout meets the recorded 5 ms target or a human explicitly accepts a
      measured exception.
- [ ] Add/remove/resize stress tests show no row, symbol, relation, or cache growth.
- [ ] `rg 'LayoutKind|LayoutContract|set_contract|measure_and_arrange|legacy_layout_oracle' app`
      returns no product implementation matches after hard removal.
- [ ] `rg 'kiwisolver' app --glob '!**/*.test.jac'` returns no matches.
- [ ] No C, Rust, Python production solver, package vendoring, compiler patch, or runtime
      fallback flag was added.
- [ ] Human approves the source-control cutover.

---

## 11. Stop conditions and human handoff

Stop implementation and report the smallest reproducer if any of these occur:

- the required Jac source cannot compile in the explicit server codespace without
  compiler fallback;
- the existing `app/` project cannot import the new in-tree modules directly;
- correct OSP `Child`/`Layer` traversal requires a jaclang or jac-ink change;
- finite float/dict behavior is incorrect on the supported server target;
- a stable public interface would require editing `jaclang`, `jac-ink`, or `jac-client`;
- passing tests would require a compile-pipeline shim, vendored runtime, or production
  Python/C bridge; or
- the solver cannot meet correctness before the layout layer depends on it.

The handoff must state symptom, owning repository, minimal reproducer, and smallest
recommended upstream fix. Do not continue behind a temporary abstraction that makes the
workaround permanent.

---

## 12. Out of scope

- web/CSS/DOM lowering;
- publishing standalone `jac-constraints` or `jac-layout` packages;
- native/client codespace compilation of the UI path;
- C, Rust, Python, Wasm, or `kiwisolver` in production;
- aspect ratios or other cross-axis constraints;
- a general CSS flexbox/grid clone;
- compile-time validation of runtime graph layout;
- scroll represented as constraints;
- Ink, `src/`, or `templates/` changes;
- edits to jaclang, jac-ink, or jac-client; and
- keeping the old engine as a runtime safety path.

---

## 13. Progress log

| Milestone | Date | Commit | Result / benchmark |
|---|---|---|---|
| Review | 2026-08-21 | this plan update | Plan corrected for placement, module seam, solver semantics, layout policies, verification, and hard cutover. |
| M0 | 2026-08-22 | (this commit) | PASS. `constraints/algebra` + `constraints/solver` server-pinned in `app/`; kiwi-faithful required-constraint tableau; 7 tests green (`JAC_TEST_JOBS=0 jac test constraints/solver.test.jac`). Baseline: 2000 sparse row merges ~2.7 ms; 100-constraint one-shot chain solve ~7.7 ms (~77 µs/cst). Oracle venv provisions (`kiwisolver==1.5.0`); M0 system matches kiwi exactly (a=0, b=10, c=30). Decision recorded as D20. |
| M0 | | | |
| M1 | | | |
| M2 | | | |
| M3 | 2026-08-24 | `d9d1539` | PASS. Incremental solver: constraint removal, edit variables, dual optimize. 26/26 solver tests. |
| M5 (slice 1) | 2026-08-24 | (this commit) | PASS. `ui/layout_measure.jac` bounded per-node wrap cache; compiler axis phases ("h"/"v"/"full") + PartitionInfo exposure; `ui/layout_engine.jac` compute pipeline: natural widths -> H solve -> LR quantization -> wrap once -> V solve -> clips/scroll/overlay arrangement -> atomic publication. Overlay roots were missing from the compiled scope (fixed; no M4 test covered them — added). Slice 2 remains: legacy dual-run parity corpus + benchmark gate. |
| M4 | 2026-08-24 | `8a6fbaf` | PASS. Permanent types + registry lifecycle (`33018f1`); compiler templates with provenance (`ui/layout_compile.jac`, 86 tests), §7.2 largest-remainder quantizer (`ui/layout_quantize.jac`, 16 tests), `configure_main_shell_layout` in `ui.screen`. Deviation D23: partition arithmetic uses hard-claim-only split (fixed-only); soft intrinsic/bounded claims drive warnings + recursion spans only. Registry functions live in `ui.layout_state` until M6 (four permanent names collide with legacy helpers). |
| M5 | | | |
| M6 | | | |
