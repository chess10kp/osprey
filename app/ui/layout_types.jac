"""Permanent layout value types + registry lifecycle (LAYOUT-ENGINE-PLAN §3/§4).

Leaf module: imports only constraints.algebra and ui.model (for node ids). Every other layout module
(ui.layout seam, compile, measure, quantize, renderer, screen) takes these
names from here — ui.layout re-exports them so downstream callers keep a
single import surface. Splitting the values out of ui.layout keeps the
import graph acyclic: ui.layout hosts compute_layout, which needs
layout_compile, which needs these types.
"""

import from constraints.algebra {
    StrengthTier,
    is_finite,
}
import from ui.model {
    UiNode,
    node_id,
}


"""Axis-aligned terminal rectangle in cell coordinates (origin top-left)."""
obj Rect {
    has x: int = 0,
        y: int = 0,
        width: int = 0,
        height: int = 0;

    def right() -> int {
        return self.x + self.width;
    }

    def bottom() -> int {
        return self.y + self.height;
    }

    def is_empty() -> bool {
        return self.width <= 0 or self.height <= 0;
    }

    def contains_point(col: int, row: int) -> bool {
        return (
            col >= self.x
            and col < self.right()
            and row >= self.y
            and row < self.bottom()
        );
    }

    def intersects(other: Rect) -> bool {
        if self.is_empty() or other.is_empty() {
            return False;
        }
        return (
            self.x < other.right()
            and self.right() > other.x
            and self.y < other.bottom()
            and self.bottom() > other.y
        );
    }

    def copy() -> Rect {
        return Rect(
            x=self.x,
            y=self.y,
            width=self.width,
            height=self.height,
        );
    }
}


obj Size {
    has width: int = 0,
        height: int = 0;
}


def rect_union(a: Rect, b: Rect) -> Rect {
    if a.is_empty() {
        return b.copy();
    }
    if b.is_empty() {
        return a.copy();
    }
    x0 = min(a.x, b.x);
    y0 = min(a.y, b.y);
    x1 = max(a.right(), b.right());
    y1 = max(a.bottom(), b.bottom());
    return Rect(x=x0, y=y0, width=x1 - x0, height=y1 - y0);
}


enum Axis { HORIZONTAL = "horizontal", VERTICAL = "vertical" }
enum SizeMode { FIXED = "fixed", INTRINSIC = "intrinsic", BOUNDED = "bounded", FILL = "fill", GROW = "grow" }
enum Align { START = "start", CENTER = "center", END = "end", STRETCH = "stretch" }
enum OverlayAnchor { CENTER = "center", TOP = "top", BOTTOM = "bottom", LEFT = "left", RIGHT = "right" }


"""Per-axis sizing policy (plan §4.1)."""
obj AxisSize {
    has mode: SizeMode,
        minimum: float = 0.0,
        preferred: float | None = None,
        maximum: float | None = None,
        grow_weight: float = 0.0;
}


"""Permanent node layout spec (plan §4.1).

Field order puts the required axis sizes first because Jac objects follow
dataclass default rules (a plan-sanctioned spelling change)."""
obj LayoutSpec {
    has width: AxisSize,
        height: AxisSize,
        flow_axis: Axis = Axis.VERTICAL,
        cross_align: Align = Align.STRETCH,
        scroll_vertical: bool = False,
        overlay_anchor: OverlayAnchor | None = None;
}


enum LayoutSeverity { WARNING = "warning", ERROR = "error" }
enum LayoutError {
    INVALID_SPEC = "invalid_spec",
    INVALID_RELATION = "invalid_relation",
    STALE_NODE = "stale_node",
    OUT_OF_SCOPE = "out_of_scope",
    INVALID_TOPOLOGY = "invalid_topology",
    UNSATISFIABLE = "unsatisfiable",
    OVERFLOW = "overflow",
    UNSUPPORTED_AXIS_COUPLING = "unsupported_axis_coupling",
    INTERNAL_INVARIANT = "internal_invariant"
}


obj Viewport {
    has columns: int,
        rows: int;
}


obj RelationHandle {
    has id: int;
}


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


enum LayoutRelationKind {
    LEFT_OF = "left_of", RIGHT_OF = "right_of",
    ABOVE = "above", BELOW = "below",
    ALIGN_START = "align_start", ALIGN_END = "align_end",
    ALIGN_CENTER = "align_center", SAME_SIZE = "same_size"
}


"""Process-local spatial relation between two live nodes (plan §4.1).

Not an OSP edge: relations are registry data keyed by stable node ids so
a replaced node (new jid) never inherits geometry declarations."""
obj LayoutRelation {
    has owner_id: str,
        source_id: str,
        target_id: str,
        kind: LayoutRelationKind,
        axis: Axis,
        provenance: str,
        gap: float = 0.0,
        strength: StrengthTier = StrengthTier.REQUIRED;
}


"""Registered content for one node (plan §4 invariant 6)."""
obj ContentEntry {
    has lines: list[str],
        content_revision: int,
        style_revision: int;
}


"""Cached wrapped lines for one node at one integer width (plan §7.1
step 4). One entry per node — revisions are monotonic, so older wraps
are never reusable and keeping only the newest bounds memory."""
obj MeasureEntry {
    has width: int,
        content_revision: int,
        style_revision: int,
        lines: list[str];
}


"""Permanent layout registry (plan §4).

`solver` and `last_frame` carry solver state and the last published
frame. Frames are immutable by ownership convention."""
obj LayoutState {
    has viewport: Viewport = Viewport(columns=80, rows=24),
        specs: dict[str, LayoutSpec] = {},
        content: dict[str, ContentEntry] = {},
        relations: dict[int, LayoutRelation] = {},
        next_relation_id: int = 1,
        measurement_cache: dict[str, MeasureEntry] = {},
        scroll_requests: dict[str, int] = {},
        last_frame: LayoutFrame | None = None;
}


# ----------------------------------------------------------------------
# Spec construction helpers (axis sugar over AxisSize).
# ----------------------------------------------------------------------

def fill_axis() -> AxisSize {
    return AxisSize(mode=SizeMode.FILL);
}


def fixed_axis(n: float) -> AxisSize {
    return AxisSize(mode=SizeMode.FIXED, preferred=n);
}


def grow_axis(weight: float) -> AxisSize {
    return AxisSize(mode=SizeMode.GROW, grow_weight=weight);
}


def intrinsic_axis() -> AxisSize {
    return AxisSize(mode=SizeMode.INTRINSIC);
}


# ----------------------------------------------------------------------
# Registry lifecycle (plan §4).
# ----------------------------------------------------------------------

def _error(code: LayoutError, message: str, node_ids: list[str] = []) -> MutationResult {
    return MutationResult(
        ok=False,
        diagnostics=[LayoutDiagnostic(
            code=code,
            severity=LayoutSeverity.ERROR,
            message=message,
            node_ids=node_ids,
        )],
    );
}


def _ok() -> MutationResult {
    return MutationResult(ok=True);
}


"""Create an empty layout registry bounded by the initial viewport."""
def create_layout_state(columns: int = 80, rows: int = 24) -> LayoutState {
    return LayoutState(viewport=Viewport(columns=columns, rows=rows));
}


# ----------------------------------------------------------------------
# Spec validation (plan §4.1 validation rules).
# ----------------------------------------------------------------------

def _validate_axis_size(axis_name: str, size: AxisSize, node_id_str: str) -> list[LayoutDiagnostic] {
    diags: list[LayoutDiagnostic] = [];
    for value in [size.minimum, size.preferred, size.maximum] {
        if value is not None and not is_finite(value) {
            diags.append(LayoutDiagnostic(
                code=LayoutError.INVALID_SPEC,
                severity=LayoutSeverity.ERROR,
                message=axis_name + " bound is not finite",
                node_ids=[node_id_str],
            ));
        }
    }
    if diags {
        return diags;
    }
    if size.minimum < 0.0 {
        diags.append(LayoutDiagnostic(
            code=LayoutError.INVALID_SPEC,
            severity=LayoutSeverity.ERROR,
            message=axis_name + " minimum is negative",
            node_ids=[node_id_str],
        ));
    }
    if size.maximum is not None and size.minimum > size.maximum {
        diags.append(LayoutDiagnostic(
            code=LayoutError.INVALID_SPEC,
            severity=LayoutSeverity.ERROR,
            message=axis_name + " minimum exceeds maximum",
            node_ids=[node_id_str],
        ));
    }
    if size.mode == SizeMode.FIXED and size.preferred is None {
        diags.append(LayoutDiagnostic(
            code=LayoutError.INVALID_SPEC,
            severity=LayoutSeverity.ERROR,
            message=axis_name + " FIXED requires preferred",
            node_ids=[node_id_str],
        ));
    }
    if size.mode == SizeMode.GROW and (not is_finite(size.grow_weight) or size.grow_weight <= 0.0) {
        diags.append(LayoutDiagnostic(
            code=LayoutError.INVALID_SPEC,
            severity=LayoutSeverity.ERROR,
            message=axis_name + " GROW requires a positive finite weight",
            node_ids=[node_id_str],
        ));
    }
    return diags;
}


def _kind_label(kind: LayoutRelationKind) -> str {
    if kind == LayoutRelationKind.LEFT_OF { return "LEFT_OF"; }
    if kind == LayoutRelationKind.RIGHT_OF { return "RIGHT_OF"; }
    if kind == LayoutRelationKind.ABOVE { return "ABOVE"; }
    if kind == LayoutRelationKind.BELOW { return "BELOW"; }
    if kind == LayoutRelationKind.ALIGN_START { return "ALIGN_START"; }
    if kind == LayoutRelationKind.ALIGN_END { return "ALIGN_END"; }
    if kind == LayoutRelationKind.ALIGN_CENTER { return "ALIGN_CENTER"; }
    return "SAME_SIZE";
}


def _axis_label(axis: Axis) -> str {
    if axis == Axis.HORIZONTAL { return "horizontal"; }
    return "vertical";
}


"""Validate one spec against the §4.1 rules; returns ERROR diagnostics
(empty when the spec is well formed)."""
def validate_spec(spec: LayoutSpec, node_id_str: str = "") -> list[LayoutDiagnostic] {
    diags = _validate_axis_size("width", spec.width, node_id_str);
    for d in _validate_axis_size("height", spec.height, node_id_str) {
        diags.append(d);
    }
    return diags;
}


# ----------------------------------------------------------------------
# Registration.
# ----------------------------------------------------------------------

"""Install or replace the permanent spec for a live node."""
def set_spec(state: LayoutState, target: UiNode, spec: LayoutSpec) -> MutationResult {
    id_str = node_id(target);
    diags = validate_spec(spec, id_str);
    if diags {
        return MutationResult(ok=False, diagnostics=diags);
    }
    state.specs[id_str] = spec;
    return _ok();
}


"""Axis/kind compatibility plus gap rules (plan §4.1)."""
def _validate_relation_shape(rel: LayoutRelation) -> LayoutDiagnostic | None {
    directional = (
        rel.kind == LayoutRelationKind.LEFT_OF
        or rel.kind == LayoutRelationKind.RIGHT_OF
        or rel.kind == LayoutRelationKind.ABOVE
        or rel.kind == LayoutRelationKind.BELOW
    );
    alignment = (
        rel.kind == LayoutRelationKind.ALIGN_START
        or rel.kind == LayoutRelationKind.ALIGN_END
        or rel.kind == LayoutRelationKind.ALIGN_CENTER
        or rel.kind == LayoutRelationKind.SAME_SIZE
    );
    if directional {
        horizontal_kind = (
            rel.kind == LayoutRelationKind.LEFT_OF
            or rel.kind == LayoutRelationKind.RIGHT_OF
        );
        expected = Axis.HORIZONTAL if horizontal_kind else Axis.VERTICAL;
        if rel.axis != expected {
            return LayoutDiagnostic(
                code=LayoutError.INVALID_RELATION,
                severity=LayoutSeverity.ERROR,
                message=_kind_label(rel.kind) + " requires axis "
                        + _axis_label(expected),
            );
        }
    }
    if not is_finite(rel.gap) or rel.gap < 0.0 {
        return LayoutDiagnostic(
            code=LayoutError.INVALID_RELATION,
            severity=LayoutSeverity.ERROR,
            message="relation gap must be finite and non-negative",
        );
    }
    if alignment and rel.gap != 0.0 {
        return LayoutDiagnostic(
            code=LayoutError.INVALID_RELATION,
            severity=LayoutSeverity.ERROR,
            message="alignment/size relations require gap == 0",
        );
    }
    return None;
}


"""Register a spatial relation; validates liveness, shape, owner, and
duplicate policy (plan §4.1)."""
def add_relation(state: LayoutState, relation: LayoutRelation) -> MutationResult {
    diag = _validate_relation_shape(relation);
    if diag is not None {
        return MutationResult(ok=False, diagnostics=[diag]);
    }
    missing: list[str] = [];
    if relation.source_id not in state.specs {
        missing.append(relation.source_id);
    }
    if relation.target_id not in state.specs {
        missing.append(relation.target_id);
    }
    if missing {
        return _error(
            LayoutError.STALE_NODE,
            "relation endpoints are not registered",
            missing,
        );
    }
    if relation.owner_id not in state.specs {
        return _error(
            LayoutError.STALE_NODE,
            "relation owner is not registered",
            [relation.owner_id],
        );
    }

    # Exact-duplicate policy: same kind/axis/pair/gap/strength merges
    # provenance into the stored relation; same expression with a
    # different strength is INVALID_RELATION (plan §4.1).
    for existing in state.relations.values() {
        if (
            existing.source_id == relation.source_id
            and existing.target_id == relation.target_id
            and existing.kind == relation.kind
            and existing.axis == relation.axis
            and existing.gap == relation.gap
        ) {
            if existing.strength == relation.strength {
                if relation.provenance not in [
                    p for p in [existing.provenance]
                ] {
                    existing.provenance = (
                        existing.provenance + ";" + relation.provenance
                    );
                }
                return _ok();
            }
            return _error(
                LayoutError.INVALID_RELATION,
                "duplicate relation expression with different strength",
                [relation.source_id, relation.target_id],
            );
        }
    }

    handle = RelationHandle(id=state.next_relation_id);
    state.next_relation_id += 1;
    state.relations[handle.id] = LayoutRelation(
        owner_id=relation.owner_id,
        source_id=relation.source_id,
        target_id=relation.target_id,
        kind=relation.kind,
        axis=relation.axis,
        gap=relation.gap,
        strength=relation.strength,
        provenance=relation.provenance,
    );
    return MutationResult(ok=True, relation_handle=handle);
}


"""Remove one relation by handle."""
def remove_relation(state: LayoutState, handle: RelationHandle) -> MutationResult {
    if handle.id not in state.relations {
        return _error(LayoutError.INVALID_RELATION, "unknown relation handle");
    }
    state.relations.pop(handle.id);
    return _ok();
}


# ----------------------------------------------------------------------
# Content, scroll, clearing.
# ----------------------------------------------------------------------

"""Attach wrapped-source content with monotonic revisions (plan §4
invariant 6)."""
def set_content(
    state: LayoutState,
    target: UiNode,
    lines: list[str],
    content_revision: int,
    style_revision: int = 0,
) -> MutationResult {
    id_str = node_id(target);
    if id_str not in state.specs {
        return _error(LayoutError.STALE_NODE, "content for unregistered node", [id_str]);
    }
    prior = state.content.get(id_str);
    if prior is not None and (
        content_revision < prior.content_revision
        or style_revision < prior.style_revision
    ) {
        return _error(
            LayoutError.INVALID_SPEC,
            "content/style revisions cannot decrease",
            [id_str],
        );
    }
    state.content[id_str] = ContentEntry(
        lines=[line for line in lines],
        content_revision=content_revision,
        style_revision=style_revision,
    );
    state.measurement_cache.pop(id_str, None);
    return _ok();
}


"""Record a requested scroll offset (clamping happens at publication)."""
def set_scroll_offset(state: LayoutState, target: UiNode, requested_offset: int) -> MutationResult {
    id_str = node_id(target);
    if id_str not in state.specs {
        return _error(LayoutError.STALE_NODE, "scroll for unregistered node", [id_str]);
    }
    state.specs[id_str].scroll_vertical = True;
    state.scroll_requests[id_str] = max(0, requested_offset);
    entry = state.content.get(id_str);
    if entry is None {
        state.content[id_str] = ContentEntry(
            lines=[],
            content_revision=0,
            style_revision=0,
        );
    }
    return _ok();
}


"""Remove everything known about a node: spec, content, cache, and every
relation it owns or touches (plan §4 invariant 5)."""
def clear_node(state: LayoutState, target: UiNode) -> MutationResult {
    id_str = node_id(target);
    doomed: list[int] = [];
    for rid in sorted(state.relations.keys()) {
        rel = state.relations[rid];
        if (
            rel.owner_id == id_str
            or rel.source_id == id_str
            or rel.target_id == id_str
        ) {
            doomed.append(rid);
        }
    }
    for rid in doomed {
        state.relations.pop(rid);
    }
    state.specs.pop(id_str, None);
    state.content.pop(id_str, None);
    state.measurement_cache.pop(id_str, None);
    return _ok();
}


"""Deep-copy accessors over the last published frame (plan §4 invariant 2).
Both return None before the first successful compute_layout."""
def frame_entry_of(state: LayoutState, target: UiNode) -> FrameEntry | None {
    if state.last_frame is None {
        return None;
    }
    entry = state.last_frame.entries.get(node_id(target));
    if entry is None {
        return None;
    }
    return FrameEntry(
        measured=Size(width=entry.measured.width, height=entry.measured.height),
        rect=_copy_rect(entry.rect),
        clip=_copy_rect(entry.clip),
        wrapped_lines=[line for line in entry.wrapped_lines],
        requested_scroll_offset=entry.requested_scroll_offset,
        scroll_offset=entry.scroll_offset,
        max_scroll_offset=entry.max_scroll_offset,
    );
}


def rect_of(state: LayoutState, target: UiNode) -> Rect | None {
    entry = frame_entry_of(state, target);
    if entry is None {
        return None;
    }
    return _copy_rect(entry.rect);
}


def _copy_rect(r: Rect) -> Rect {
    return Rect(x=r.x, y=r.y, width=r.width, height=r.height);
}
