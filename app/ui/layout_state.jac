"""Registry lifecycle for the permanent constraint-layout interface.

LAYOUT-ENGINE-PLAN §4: LayoutState owns specs, content revisions, relations,
and (from M5) solver state and the last published frame. The lifecycle
functions live here — not in ui.layout — because four permanent names
(set_content, clear_node, rect_of, set_scroll_offset) collide with legacy
contract-table helpers that renderer/gates still call until M6. At cutover
these functions move into ui.layout and this module disappears.

Validation policy (plan §4/§6): every mutation is atomic and returns a
typed MutationResult; failures carry diagnostics with provenance and leave
the registry unchanged.
"""

import from constraints.algebra {
    StrengthTier,
    is_finite,
}
import from ui.layout {
    Align,
    Axis,
    AxisSize,
    FrameEntry,
    LayoutDiagnostic,
    LayoutError,
    LayoutFrame,
    LayoutRelation,
    LayoutRelationKind,
    LayoutSeverity,
    LayoutSpec,
    MutationResult,
    OverlayAnchor,
    Rect,
    RelationHandle,
    Size,
    SizeMode,
    Viewport,
}
import from ui.model {
    UiNode,
    child_parent,
    node_id,
}


"""Registered content for one node (plan §4 invariant 6)."""
obj ContentEntry {
    has lines: list[str],
        content_revision: int,
        style_revision: int;
}


"""Permanent layout registry (plan §4).

`solver` and `last_frame` are populated from M5; the fields exist now so
the shape is locked. Frames are immutable by ownership convention."""
obj LayoutState {
    has viewport: Viewport = Viewport(columns=80, rows=24),
        specs: dict[str, LayoutSpec] = {},
        content: dict[str, ContentEntry] = {},
        relations: dict[int, LayoutRelation] = {},
        next_relation_id: int = 1,
        measurement_cache: dict[str, list[str]] = {},
        last_frame: LayoutFrame | None = None;
}


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


"""True when both endpoints name nodes registered through set_spec."""
def _endpoints_live(state: LayoutState, rel: LayoutRelation) -> bool {
    return rel.source_id in state.specs and rel.target_id in state.specs;
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
    # Requested offset rides on content until M5 publishes frames.
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
Both return None until M5 starts publishing frames."""
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
