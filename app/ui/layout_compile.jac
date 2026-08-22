"""Constraint compilation: registry + Child/Layer topology -> solver facts.

LAYOUT-ENGINE-PLAN §6: each live node gets four external variables
(left/top/right/bottom); width and height are derived expressions, never
separately mutable facts. Every generated constraint carries provenance
(template, node id, axis, and source spec/relation handle).

Templates (plan §6.1):

- root        required pinning of the layout root's four edges to the
              declared viewport
- invariant   required right >= left / bottom >= top for every node
- fixed       required axis-size equality
- intrinsic   weak preference for measured natural size when known
- bounded     required min/max plus optional weak preferred equality
- fill/stretch cross-axis pinning of both edges to the parent content box
- flow        required sibling adjacency chain along the flow axis
- grow        §6.2 bounded proportional allocation, emitted as exact
              continuous equalities (quantization is §7.2's job)
- overlay     out-of-flow sizing plus STRONG anchor equations against the
              root box (STRONG, not REQUIRED: an oversized fixed overlay
              must stay solvable; origin clamping happens at publication)

Grow allocation is a deterministic TOP-DOWN CONTINUOUS PASS over the
declared viewport: the root span is the viewport, and each child's flow
span is the target allocated by its parent's partition (plan §6.2). The
solver verifies the emitted equalities; it is not asked to discover them.

Cross-axis decision rule (documented policy): FILL and GROW pin both
edges; STRETCH also pins unless the cross mode is FIXED (an explicit size
beats stretch, matching CSS align-items semantics for auto boxes);
otherwise the size templates emit and cross_align positions the child
START/CENTER/END within the parent box.

Provenance template names are named by TRIGGER (what caused the
constraint), not by effect (the pin itself):

  Trigger                              Template name
  -----------------------------------  -------------
  viewport input pins root edges       root
  geometric invariant (R>=L, B>=T)     invariant
  cross AxisMode == FIXED size         fixed
  cross AxisMode == INTRINSIC          intrinsic
  cross AxisMode == BOUNDED            bounded
  cross AxisMode == FILL pin           fill
  cross AxisMode == GROW pin           stretch   (NOT "grow": that is the
                                                  flow-axis allocator)
  flow adjacency chain                 flow
  flow grow allocation equality        grow      (carries weight + target)
  Layer-reached overlay sizing         overlay
  registered LayoutRelation            relation (carries rel=N)

The compiler never measures text (M5 owns measurement) and never
quantizes (§7.2 owns that). Scope validation rejects cycles, multiple
Child parents, duplicate visits, missing specs, out-of-scope relations,
and relation owners that are not the direct Child parent of both
endpoints. Any rejected constraint aborts atomically: ok=False, no
usable solver (plan §4 invariant 4).
"""

import from constraints.algebra {
    Constraint,
    Expression,
    Relation,
    StrengthTier,
    Term,
    Variable,
    is_finite,
    normalize_expression,
}
import from constraints.solver {
    SolveError,
    Solver,
}
import from ui.layout {
    Align,
    AxisSize,
    LayoutDiagnostic,
    LayoutError,
    LayoutRelation,
    LayoutRelationKind,
    LayoutSeverity,
    LayoutSpec,
    OverlayAnchor,
    Size,
    SizeMode,
    Viewport,
}
import from ui.layout_state {
    LayoutState,
}
import from ui.model {
    Layer,
    Overlay,
    Screen,
    UiContainer,
    UiNode,
    node_id,
    ordered_children,
}


"""The four edge variables for one laid-out node (plan §6)."""
obj NodeEdges {
    has id_str: str,
        key: str,
        left: Variable,
        top: Variable,
        right: Variable,
        bottom: Variable;
}


"""Compilation outcome. On ok=False the solver is absent (atomic abort);
diagnostics carry provenance for every implicated source."""
obj CompileResult {
    has ok: bool = True,
        solver: Solver | None = None,
        nodes: dict[str, NodeEdges] = {},
        diagnostics: list[LayoutDiagnostic] = [];
}


obj _ScopedNode {
    has target: UiNode,
        id_str: str = "",
        key: str = "",
        parent_id: str = "",
        rank: int = 0,
        is_overlay: bool = False,
        z_index: int = 0;
}


obj _Scope {
    has order: list[_ScopedNode] = [],
        parent_of: dict[str, str] = {},
        error: LayoutDiagnostic | None = None;
}


obj _Entry {
    has scoped: _ScopedNode,
        edges: NodeEdges,
        spec: LayoutSpec;
}


obj _FlowChild {
    has entry: _Entry,
        size: AxisSize,
        natural: float | None = None;
}


obj _Allocation {
    has targets: list[float] = [],
        # Warning-worthy: hard OR soft non-grow claims exceed the span.
        overflow: bool = False,
        # Contradiction-worthy: REQUIRED-exact (FIXED) claims alone
        # exceed the span, so the closing edge must be omitted.
        hard_overflow: bool = False;
}


# ----------------------------------------------------------------------
# Scope collection (plan §6 topology validation).
# ----------------------------------------------------------------------

def _topology_error(message: str) -> LayoutDiagnostic {
    return LayoutDiagnostic(
        code=LayoutError.INVALID_TOPOLOGY,
        severity=LayoutSeverity.ERROR,
        message=message,
    );
}


def _z_index_of(screen: Screen, overlay: Overlay) -> int {
    for edge in [edge screen ->:Layer:-> overlay] {
        return int(edge.z_index);
    }
    return 0;
}


def _scoped_jid_key(pair: _ScopedNode) -> str {
    return pair.id_str;
}


def _scoped_z_key(pair: _ScopedNode) -> int {
    return pair.z_index;
}


"""Collect Layer-reached overlays owned by a Screen root.

Equal z_index breaks ties by stable jid (plan §6.3): sort by jid first,
then stably by z_index."""
def _collect_overlays(layout_root: UiNode, seen: dict[str, bool]) -> list[_ScopedNode] {
    found: list[_ScopedNode] = [];
    if not isinstance(layout_root, Screen) {
        return found;
    }
    for ov in [layout_root ->:Layer:->] {
        oid = node_id(ov);
        if oid in seen {
            continue;
        }
        seen[oid] = True;
        found.append(_ScopedNode(
            target=ov,
            id_str=oid,
            key=str(ov.key),
            is_overlay=True,
            z_index=_z_index_of(layout_root, ov),
        ));
    }
    found.sort(key=_scoped_jid_key);
    found.sort(key=_scoped_z_key);
    return found;
}


"""Append parent's ordered children to the scope.

`in_flow_walk` is True for the normal-flow tree from the root: Layer-
reached overlays are skipped there (they are out of flow). Overlay
subtree walks pass False; their descendants are ordinary flow children
of the overlay. Returns False and sets scope.error on a revisit."""
def _walk_children(
    parent_target: UiContainer,
    parent_id: str,
    in_flow_walk: bool,
    overlay_ids: dict[str, bool],
    seen: dict[str, bool],
    scope: _Scope,
    queue: list[_ScopedNode],
) -> bool {
    for child in ordered_children(parent_target) {
        cid = node_id(child);
        if cid in overlay_ids {
            if in_flow_walk {
                continue;
            }
            # Overlay-subtree walk reaching a Layer-reached node again
            # means it was also declared a Child of an overlay subtree.
            scope.error = _topology_error(
                "Layer overlay nested under another overlay: " + cid
            );
            return False;
        }
        if cid in seen {
            scope.error = _topology_error(
                "node visited twice in one scope (cycle or diamond): " + cid
            );
            return False;
        }
        seen[cid] = True;
        rank_val = 0;
        for edge in [edge parent_target ->:Child:-> child] {
            rank_val = int(edge.rank);
            break;
        }
        scoped = _ScopedNode(
            target=child,
            id_str=cid,
            key=str(child.key),
            parent_id=parent_id,
            rank=rank_val,
        );
        scope.order.append(scoped);
        scope.parent_of[cid] = parent_id;
        queue.append(scoped);
    }
    return True;
}


def _collect_scope(layout_root: UiNode) -> _Scope {
    scope = _Scope();
    seen: dict[str, bool] = {};
    overlay_ids: dict[str, bool] = {};

    overlays = _collect_overlays(layout_root, seen);
    for scoped in overlays {
        overlay_ids[scoped.id_str] = True;
    }

    root_id = node_id(layout_root);
    seen[root_id] = True;
    root_scoped = _ScopedNode(target=layout_root, id_str=root_id, key=layout_root.key);
    scope.order.append(root_scoped);

    # BFS over the normal-flow tree, skipping overlay subtrees.
    queue: list[_ScopedNode] = [root_scoped];
    while len(queue) {
        current = queue.pop(0);
        if len([current.target <-:Child:<-]) > 1 {
            scope.error = _topology_error(
                "node has multiple Child parents: " + current.id_str
            );
            return scope;
        }
        if isinstance(current.target, UiContainer) {
            ok = _walk_children(
                current.target,
                current.id_str,
                True,
                overlay_ids,
                seen,
                scope,
                queue,
            );
            if not ok {
                return scope;
            }
        }
    }

    # Overlay subtrees append after the flow tree, in overlay order.
    queue = overlays;
    while len(queue) {
        current = queue.pop(0);
        if isinstance(current.target, UiContainer) {
            # Real overlay_ids (not {}): a Layer-reached node appearing
            # as a Child inside another overlay's subtree is a specific
            # topology error, not a generic revisit.
            ok = _walk_children(
                current.target,
                current.id_str,
                False,
                overlay_ids,
                seen,
                scope,
                queue,
            );
            if not ok {
                return scope;
            }
        }
    }
    return scope;
}


# ----------------------------------------------------------------------
# Expression and emission helpers.
# ----------------------------------------------------------------------

def _t(v: Variable, coefficient: float = 1.0) -> Term {
    return Term(variable=v, coefficient=coefficient);
}


def _expr(terms: list[Term], constant: float = 0.0) -> Expression {
    return normalize_expression(Expression(terms=terms, constant=constant));
}


"""Provenance string per plan §6: template name, node jid (+ semantic
key when known), axis, parent jid + rank when relevant, the declaring
source (spec / relation handle), and any extra facts (grow weight and
continuous target). Deterministic; consumed by UNSATISFIABLE witness
diagnostics so failures point back to the registration site."""
def _prov(
    template: str,
    id_str: str,
    axis_label: str,
    key: str = "",
    parent: str = "",
    rank: int = -1,
    src: str = "",
    extra: str = "",
) -> str {
    out = "template=" + template + " node=" + id_str;
    if key != "" {
        out = out + ":" + key;
    }
    out = out + " axis=" + axis_label;
    if parent != "" {
        out = out + " parent=" + parent + "#" + str(rank);
    }
    if src != "" {
        out = out + " src=" + src;
    }
    if extra != "" {
        out = out + " " + extra;
    }
    return out;
}


"""Emit one constraint; on rejection attach a diagnostic with provenance
and flip the result to failed. Returns True only on success."""
def _emit(
    result: CompileResult,
    expr: Expression,
    relation: Relation,
    strength: StrengthTier,
    provenance: str,
) -> bool {
    s = result.solver;
    if s is None {
        return False;  # Aborted compile; nothing further to emit into.
    }
    c = Constraint(expression=expr, relation=relation, strength=strength);
    res = s.add_constraint(c, provenance=provenance);
    if not res.ok {
        code = LayoutError.INVALID_RELATION;
        if res.error == SolveError.UNSATISFIABLE {
            code = LayoutError.UNSATISFIABLE;
        }
        witnesses = [provenance];
        for w in res.witness_provenance {
            witnesses.append(w);
        }
        result.diagnostics.append(LayoutDiagnostic(
            code=code,
            severity=LayoutSeverity.ERROR,
            message=res.message,
            provenance=witnesses,
        ));
        result.ok = False;
        return False;
    }
    return True;
}


# ----------------------------------------------------------------------
# Templates.
# ----------------------------------------------------------------------

def _axis_start(edges: NodeEdges, horizontal: bool) -> Variable {
    return edges.left if horizontal else edges.top;
}


def _axis_end(edges: NodeEdges, horizontal: bool) -> Variable {
    return edges.right if horizontal else edges.bottom;
}


def _emit_pin_edge(
    result: CompileResult,
    v: Variable,
    target: float,
    id_str: str,
    axis_label: str,
) -> bool {
    return _emit(
        result,
        _expr([_t(v)], -target),
        Relation.EQ,
        StrengthTier.REQUIRED,
        _prov("root", id_str, axis_label),
    );
}


"""Required viewport pinning of the root's four edges (plan §6.1)."""
def _emit_root(result: CompileResult, edges: NodeEdges, viewport: Viewport) -> bool {
    id_str = edges.id_str;
    if not _emit_pin_edge(result, edges.left, 0.0, id_str, "h") {
        return False;
    }
    if not _emit_pin_edge(result, edges.top, 0.0, id_str, "v") {
        return False;
    }
    if not _emit_pin_edge(
        result, edges.right, float(viewport.columns), id_str, "h"
    ) {
        return False;
    }
    return _emit_pin_edge(
        result, edges.bottom, float(viewport.rows), id_str, "v"
    );
}


def _emit_invariants(result: CompileResult, edges: NodeEdges) -> bool {
    id_str = edges.id_str;
    if not _emit(
        result,
        _expr([_t(edges.right), _t(edges.left, -1.0)]),
        Relation.GEQ,
        StrengthTier.REQUIRED,
        _prov("invariant", edges.id_str, "h"),
    ) {
        return False;
    }
    return _emit(
        result,
        _expr([_t(edges.bottom), _t(edges.top, -1.0)]),
        Relation.GEQ,
        StrengthTier.REQUIRED,
        _prov("invariant", edges.id_str, "v"),
    );
}


"""FIXED / INTRINSIC / BOUNDED sizing on one axis (plan §6.1)."""
def _emit_sized_axis(
    result: CompileResult,
    size: AxisSize,
    start: Variable,
    end: Variable,
    horizontal: bool,
    id_str: str,
    natural: float | None,
    src_extra: str,
) -> bool {
    label = "h" if horizontal else "v";
    span_terms = [_t(end), _t(start, -1.0)];
    if size.mode == SizeMode.FIXED {
        return _emit(
            result,
            _expr(span_terms, -_req(size.preferred)),
            Relation.EQ,
            StrengthTier.REQUIRED,
            _prov("fixed", id_str, label, src_extra),
        );
    }
    if size.mode == SizeMode.INTRINSIC {
        if natural is None {
            return True;  # Measurement lands in M5; invariants suffice.
        }
        return _emit(
            result,
            _expr(span_terms, -natural),
            Relation.EQ,
            StrengthTier.WEAK,
            _prov("intrinsic", id_str, label, src_extra),
        );
    }
    if size.mode == SizeMode.BOUNDED {
        if size.minimum > 0.0 {
            if not _emit(
                result,
                _expr(span_terms, -size.minimum),
                Relation.GEQ,
                StrengthTier.REQUIRED,
                _prov("bounded", id_str, label, src_extra),
            ) {
                return False;
            }
        }
        if size.maximum is not None and is_finite(size.maximum) {
            if not _emit(
                result,
                _expr(span_terms, -size.maximum),
                Relation.LEQ,
                StrengthTier.REQUIRED,
                _prov("bounded", id_str, label, src_extra),
            ) {
                return False;
            }
        }
        if size.preferred is not None {
            return _emit(
                result,
                _expr(span_terms, -_req(size.preferred)),
                Relation.EQ,
                StrengthTier.WEAK,
                _prov("bounded", id_str, label, src_extra),
            );
        }
        return True;
    }
    # FILL / GROW are handled by the caller (pin or partition).
    return True;
}


"""Pin both edges of a child to the parent content box on one axis."""
def _emit_pin(
    result: CompileResult,
    child_start: Variable,
    child_end: Variable,
    parent_start: Variable,
    parent_end: Variable,
    horizontal: bool,
    id_str: str,
    template: str,
) -> bool {
    label = "h" if horizontal else "v";
    if not _emit(
        result,
        _expr([_t(child_start), _t(parent_start, -1.0)]),
        Relation.EQ,
        StrengthTier.REQUIRED,
        _prov(template, id_str, label),
    ) {
        return False;
    }
    return _emit(
        result,
        _expr([_t(child_end), _t(parent_end, -1.0)]),
        Relation.EQ,
        StrengthTier.REQUIRED,
        _prov(template, id_str, label),
    );
}


"""Position a sized child on the cross axis per cross_align."""
def _emit_cross_align(
    result: CompileResult,
    child: NodeEdges,
    parent: NodeEdges,
    spec: LayoutSpec,
    horizontal: bool,
) -> bool {
    label = "h" if horizontal else "v";
    start_c = _axis_start(child, horizontal);
    end_c = _axis_end(child, horizontal);
    start_p = _axis_start(parent, horizontal);
    end_p = _axis_end(parent, horizontal);
    if spec.cross_align == Align.START {
        return _emit(
            result,
            _expr([_t(start_c), _t(start_p, -1.0)]),
            Relation.EQ,
            StrengthTier.REQUIRED,
            _prov("align", child.id_str, label),
        );
    }
    if spec.cross_align == Align.END {
        return _emit(
            result,
            _expr([_t(end_c), _t(end_p, -1.0)]),
            Relation.EQ,
            StrengthTier.REQUIRED,
            _prov("align", child.id_str, label),
        );
    }
    if spec.cross_align == Align.CENTER {
        return _emit(
            result,
            _expr([_t(start_c), _t(end_c), _t(start_p, -1.0), _t(end_p, -1.0)]),
            Relation.EQ,
            StrengthTier.REQUIRED,
            _prov("align", child.id_str, label),
        );
    }
    return True;  # STRETCH never reaches here (handled as pins).
}


# ----------------------------------------------------------------------
# Grow allocation (plan §6.2) — continuous targets, pre-constraint.
# ----------------------------------------------------------------------

def _flow_weight(size: AxisSize) -> float {
    if size.mode == SizeMode.GROW {
        return size.grow_weight;
    }
    if size.mode == SizeMode.FILL {
        return 1.0;
    }
    return 0.0;
}


"""Hard partition claim: only REQUIRED-exact sizes count. FIXED is a
required equality so its claim is load-bearing; every other non-flex
mode emits soft (WEAK) preferences and must NOT bear on the hard
partition arithmetic — a WEAK input inside a REQUIRED closure would let
solver drift turn the whole frame unsatisfiable (GoldLion review, BUG B).
This deliberately narrows plan §6.2 step 2 ("fixed/intrinsic/bounded
non-grow claims") to fixed-only; the soft claims still drive the OVERFLOW
warning via _flow_soft_claim."""
def _flow_hard_claim(size: AxisSize) -> float {
    if size.mode == SizeMode.FIXED {
        return _req(size.preferred);
    }
    return 0.0;
}


"""Soft best-estimate claim (plan §6.2 step 2 as written): used for the
OVERFLOW warning and for recursion spans of inflexible children — never
for hard partition arithmetic."""
def _flow_soft_claim(size: AxisSize, natural: float | None) -> float {
    if size.mode == SizeMode.FIXED {
        return _req(size.preferred);
    }
    if size.preferred is not None {
        return size.preferred;
    }
    if natural is not None {
        return natural;
    }
    if size.mode == SizeMode.BOUNDED {
        return size.minimum;
    }
    return 0.0;
}


"""Unwrap a float-or-None that is semantically required (FIXED mode
guarantees a preferred value; validation enforces it). Falls back to
0.0 only to satisfy the type checker on impossible paths."""
def _req(v: float | None) -> float {
    if v is None {
        return 0.0;
    }
    return v;
}


"""Bounded proportional allocation with freeze-at-bound iteration
(plan §6.2 steps 2–5, with the §4.1-review hard/soft claim split).
Arithmetic uses hard claims only; `overflow` is flagged when either the
hard or the soft non-grow claims exceed the span (warning either way,
solver contradiction only in the hard case). Never returns negative
targets; grow children absorb zero when the hard remainder is spent."""
def _allocate_span(children: list[_FlowChild], span: float) -> _Allocation {
    n = len(children);
    alloc = _Allocation(targets=[0.0] * n);
    hard_sum = 0.0;
    soft_sum = 0.0;
    for i in range(n) {
        size = children[i].size;
        if _flow_weight(size) == 0.0 {
            hard_sum += max(0.0, _flow_hard_claim(size));
            soft_sum += max(0.0, _flow_soft_claim(size, children[i].natural));
        }
    }
    remaining = span - hard_sum;
    if remaining < 0.0 or soft_sum > span + 1e-8 {
        alloc.overflow = True;
        remaining = max(0.0, remaining);
    }
    if hard_sum > span + 1e-8 {
        alloc.hard_overflow = True;
    }
    active: list[int] = [];
    for i in range(n) {
        if _flow_weight(children[i].size) > 0.0 {
            active.append(i);
        } else {
            # Best-estimate target for inflexible children: drives the
            # recursion span for containers, never a hard equality.
            alloc.targets[i] = max(0.0, _flow_soft_claim(
                children[i].size, children[i].natural
            ));
        }
    }
    while len(active) {
        wsum = 0.0;
        for i in active {
            wsum += _flow_weight(children[i].size);
        }
        if wsum <= 0.0 {
            for i in active {
                alloc.targets[i] = 0.0;
            }
            break;
        }
        frozen: list[int] = [];
        for i in active {
            share = remaining * (_flow_weight(children[i].size) / wsum);
            mx = children[i].size.maximum;
            if share < children[i].size.minimum - 1e-8 {
                alloc.targets[i] = max(0.0, children[i].size.minimum);
                remaining -= alloc.targets[i];
                frozen.append(i);
            } elif mx is not None and share > mx + 1e-8 {
                alloc.targets[i] = mx;
                remaining -= mx;
                frozen.append(i);
            }
        }
        if not frozen {
            for i in active {
                alloc.targets[i] = max(
                    0.0, remaining * (_flow_weight(children[i].size) / wsum)
                );
            }
            break;
        }
        next_active: list[int] = [];
        for i in active {
            is_frozen = False;
            for f in frozen {
                if f == i {
                    is_frozen = True;
                }
            }
            if not is_frozen {
                next_active.append(i);
            }
        }
        active = next_active;
    }
    for i in range(n) {
        if alloc.targets[i] < 0.0 {
            alloc.targets[i] = 0.0;
        }
    }
    return alloc;
}


# ----------------------------------------------------------------------
# Flow partition + subtree emission.
# ----------------------------------------------------------------------

"""Compile one container's flow partition along spec.flow_axis: grow
allocation over the declared span, adjacency chain, per-child size facts,
cross-axis resolution, partition-closing edge when flexible, and
recursion into child containers with their allocated spans."""
def _emit_partition(
    result: CompileResult,
    owner: _Entry,
    entries_by_id: dict[str, _Entry],
    natural_sizes: dict[str, Size],
    span_w: float,
    span_h: float,
) -> bool {
    spec = owner.spec;
    parent_edges = owner.edges;
    horizontal_flow = spec.flow_axis.value == "horizontal";
    flow_label = "h" if horizontal_flow else "v";

    flow_kids: list[_FlowChild] = [];
    for scoped in _ordered_flow_children(owner, entries_by_id) {
        child_spec = scoped.spec;
        nat: float | None = None;
        nid = scoped.edges.id_str;
        if horizontal_flow {
            size_axis = child_spec.width;
            if nid in natural_sizes {
                nat = float(natural_sizes[nid].width);
            }
        } else {
            size_axis = child_spec.height;
            if nid in natural_sizes {
                nat = float(natural_sizes[nid].height);
            }
        }
        flow_kids.append(_FlowChild(entry=scoped, size=size_axis, natural=nat));
    }

    span_flow = span_w if horizontal_flow else span_h;
    alloc = _allocate_span(flow_kids, span_flow);
    if alloc.overflow {
        result.diagnostics.append(LayoutDiagnostic(
            code=LayoutError.OVERFLOW,
            severity=LayoutSeverity.WARNING,
            message="flow partition exceeds parent span; "
                    "non-flexible claims kept",
            node_ids=[parent_edges.id_str],
        ));
    }

    # Adjacency chain: first start pinned to parent start; siblings chain.
    if len(flow_kids) {
        if not _emit(
            result,
            _expr([
                _t(_axis_start(flow_kids[0].entry.edges, horizontal_flow)),
                _t(_axis_start(parent_edges, horizontal_flow), -1.0),
            ]),
            Relation.EQ,
            StrengthTier.REQUIRED,
            _prov("flow", parent_edges.id_str, flow_label),
        ) {
            return False;
        }
        for i in range(1, len(flow_kids)) {
            if not _emit(
                result,
                _expr([
                    _t(_axis_start(flow_kids[i].entry.edges, horizontal_flow)),
                    _t(_axis_end(flow_kids[i - 1].entry.edges, horizontal_flow), -1.0),
                ]),
                Relation.EQ,
                StrengthTier.REQUIRED,
                _prov("flow", parent_edges.id_str, flow_label),
            ) {
                return False;
            }
        }
    }

    has_flexible = False;
    for i in range(len(flow_kids)) {
        kid = flow_kids[i];
        kid_edges = kid.entry.edges;
        kid_scoped = kid.entry.scoped;
        if _flow_weight(kid.size) > 0.0 {
            has_flexible = True;
            if not _emit(
                result,
                _expr([
                    _t(_axis_end(kid_edges, horizontal_flow)),
                    _t(_axis_start(kid_edges, horizontal_flow), -1.0),
                ], -alloc.targets[i]),
                Relation.EQ,
                StrengthTier.REQUIRED,
                _prov(
                    "grow", kid_edges.id_str, flow_label,
                    key=kid_edges.key,
                    parent=parent_edges.id_str,
                    rank=kid_scoped.rank,
                    src="spec",
                    extra="weight=" + repr(_flow_weight(kid.size))
                          + " target=" + repr(alloc.targets[i]),
                ),
            ) {
                return False;
            }
        } else {
            if not _emit_sized_axis(
                result,
                kid.size,
                _axis_start(kid_edges, horizontal_flow),
                _axis_end(kid_edges, horizontal_flow),
                horizontal_flow,
                kid_edges.id_str,
                kid.natural,
                "src=spec parent=" + parent_edges.id_str
                + "#" + str(kid_scoped.rank),
            ) {
                return False;
            }
        }

        # Cross-axis resolution against the parent content box. The
        # cross axis is the opposite of THIS container's flow axis.
        if not _emit_cross_axis(
            result, kid.entry, owner, natural_sizes, not horizontal_flow,
        ) {
            return False;
        }

        # Recurse: the child's own flow span is what it was allocated;
        # the cross span passes straight through from this container.
        child_span_w = alloc.targets[i] if horizontal_flow else span_w;
        child_span_h = span_h if horizontal_flow else alloc.targets[i];
        if isinstance(kid.entry.scoped.target, UiContainer) {
            if not _emit_partition(
                result, kid.entry, entries_by_id, natural_sizes,
                child_span_w, child_span_h,
            ) {
                return False;
            }
        }
    }

    # Close the partition only when a flexible child absorbs the slack;
    # otherwise trailing space stays empty like the legacy engine. On
    # overflow the closure is omitted too: fixed claims already stick
    # out of the parent and the publisher clips them (plan §6.2 step 3)
    # — forcing closure here would turn the warned overflow into an
    # UNSATISFIABLE frame.
    if has_flexible and not alloc.hard_overflow {
        last_edges = flow_kids[len(flow_kids) - 1].entry.edges;
        if not _emit(
            result,
            _expr([
                _t(_axis_end(last_edges, horizontal_flow)),
                _t(_axis_end(parent_edges, horizontal_flow), -1.0),
            ]),
            Relation.EQ,
            StrengthTier.REQUIRED,
            _prov("flow", parent_edges.id_str, flow_label),
        ) {
            return False;
        }
    }
    return True;
}


"""Ordered non-overlay Child entries of a container entry."""
def _ordered_flow_children(
    owner: _Entry,
    entries_by_id: dict[str, _Entry],
) -> list[_Entry] {
    out: list[_Entry] = [];
    if not isinstance(owner.scoped.target, UiContainer) {
        return out;
    }
    for child in ordered_children(owner.scoped.target) {
        cid = node_id(child);
        if cid in entries_by_id and not entries_by_id[cid].scoped.is_overlay {
            out.append(entries_by_id[cid]);
        }
    }
    return out;
}


"""Cross-axis facts for one flow child (see module docstring policy).

`horizontal` says whether this child's CROSS axis is horizontal — it is
always the opposite of the parent container's flow axis, so the caller
passes it; the child's own spec.flow_axis describes its children and
must not influence how the parent positions this child."""
def _emit_cross_axis(
    result: CompileResult,
    kid: _Entry,
    parent: _Entry,
    natural_sizes: dict[str, Size],
    horizontal: bool,
) -> bool {
    kid_spec = kid.spec;
    kid_edges = kid.edges;
    parent_edges = parent.edges;
    cross_mode: SizeMode;
    natural: float | None = None;
    if horizontal {
        cross_mode = kid_spec.width.mode;
        if kid_edges.id_str in natural_sizes {
            natural = float(natural_sizes[kid_edges.id_str].width);
        }
        cross_size = kid_spec.width;
    } else {
        cross_mode = kid_spec.height.mode;
        if kid_edges.id_str in natural_sizes {
            natural = float(natural_sizes[kid_edges.id_str].height);
        }
        cross_size = kid_spec.height;
    }

    stretch = (
        cross_mode == SizeMode.FILL
        or cross_mode == SizeMode.GROW
        or (kid_spec.cross_align == Align.STRETCH and cross_mode != SizeMode.FIXED)
    );
    if stretch {
        template = "fill";
        if cross_mode == SizeMode.GROW {
            template = "stretch";
        }
        return _emit_pin(
            result,
            _axis_start(kid_edges, horizontal),
            _axis_end(kid_edges, horizontal),
            _axis_start(parent_edges, horizontal),
            _axis_end(parent_edges, horizontal),
            horizontal,
            kid_edges.id_str,
            template,
        );
    }

    # Sized cross axis: bounds/min/max templates, then positioning.
    if not _emit_sized_axis(
        result,
        cross_size,
        _axis_start(kid_edges, horizontal),
        _axis_end(kid_edges, horizontal),
        horizontal,
        kid_edges.id_str,
        natural,
        "parent=" + parent_edges.id_str,
    ) {
        return False;
    }
    if kid_spec.cross_align == Align.STRETCH {
        # Sized + STRETCH degrades to START anchoring (documented).
        return True;
    }
    return _emit_cross_align(result, kid_edges, parent_edges, kid_spec, horizontal);
}


# ----------------------------------------------------------------------
# Overlays (plan §6.3).
# ----------------------------------------------------------------------

"""Out-of-flow sizing plus STRONG anchors against the root box."""
def _emit_overlay(
    result: CompileResult,
    owner: _Entry,
    root_edges: NodeEdges,
    natural_sizes: dict[str, Size],
) -> bool {
    edges = owner.edges;
    spec = owner.spec;
    id_str = edges.id_str;

    natural_w: float | None = None;
    natural_h: float | None = None;
    if id_str in natural_sizes {
        natural_w = float(natural_sizes[id_str].width);
        natural_h = float(natural_sizes[id_str].height);
    }

    if (
        spec.width.mode == SizeMode.FIXED
        or spec.width.mode == SizeMode.INTRINSIC
        or spec.width.mode == SizeMode.BOUNDED
    ) {
        if not _emit_sized_axis(
            result, spec.width, edges.left, edges.right,
            True, id_str, natural_w, "overlay",
        ) {
            return False;
        }
    }
    if (
        spec.height.mode == SizeMode.FIXED
        or spec.height.mode == SizeMode.INTRINSIC
        or spec.height.mode == SizeMode.BOUNDED
    ) {
        if not _emit_sized_axis(
            result, spec.height, edges.top, edges.bottom,
            False, id_str, natural_h, "overlay",
        ) {
            return False;
        }
    }

    # Anchors are STRONG so oversized fixed overlays stay solvable; the
    # publisher clamps origins to the root box later (plan §6.3).
    anchor = spec.overlay_anchor;
    centered_h = (
        anchor is None
        or anchor == OverlayAnchor.CENTER
        or anchor == OverlayAnchor.TOP
        or anchor == OverlayAnchor.BOTTOM
    );
    centered_v = (
        anchor is None
        or anchor == OverlayAnchor.CENTER
        or anchor == OverlayAnchor.LEFT
        or anchor == OverlayAnchor.RIGHT
    );
    if centered_h {
        if not _emit(
            result,
            _expr([
                _t(edges.left), _t(edges.right),
                _t(root_edges.left, -1.0), _t(root_edges.right, -1.0),
            ]),
            Relation.EQ,
            StrengthTier.STRONG,
            _prov("overlay", id_str, "h"),
        ) {
            return False;
        }
    }
    if centered_v {
        if not _emit(
            result,
            _expr([
                _t(edges.top), _t(edges.bottom),
                _t(root_edges.top, -1.0), _t(root_edges.bottom, -1.0),
            ]),
            Relation.EQ,
            StrengthTier.STRONG,
            _prov("overlay", id_str, "v"),
        ) {
            return False;
        }
    }
    if anchor == OverlayAnchor.TOP or anchor == OverlayAnchor.BOTTOM {
        edge_var = edges.top if anchor == OverlayAnchor.TOP else edges.bottom;
        root_var = root_edges.top if anchor == OverlayAnchor.TOP else root_edges.bottom;
        if not _emit(
            result,
            _expr([_t(edge_var), _t(root_var, -1.0)]),
            Relation.EQ,
            StrengthTier.STRONG,
            _prov("overlay", id_str, "v"),
        ) {
            return False;
        }
    }
    if anchor == OverlayAnchor.LEFT or anchor == OverlayAnchor.RIGHT {
        edge_var = edges.left if anchor == OverlayAnchor.LEFT else edges.right;
        root_var = root_edges.left if anchor == OverlayAnchor.LEFT else root_edges.right;
        if not _emit(
            result,
            _expr([_t(edge_var), _t(root_var, -1.0)]),
            Relation.EQ,
            StrengthTier.STRONG,
            _prov("overlay", id_str, "h"),
        ) {
            return False;
        }
    }
    return True;
}


# ----------------------------------------------------------------------
# Relations (plan §4.1 equation table).
# ----------------------------------------------------------------------

"""Emit one registered relation as its §4.1 equation-table entry."""
def _emit_relation(
    result: CompileResult,
    rid: int,
    rel: LayoutRelation,
    edges_by_id: dict[str, NodeEdges],
) -> bool {
    s = edges_by_id[rel.source_id];
    tgt = edges_by_id[rel.target_id];
    k = rel.kind;
    gap = rel.gap;
    horizontal_axis = rel.axis.value == "horizontal";
    axis_label = "h" if horizontal_axis else "v";
    prov = (
        "template=relation rel=" + str(rid)
        + " src=" + rel.provenance + " axis=" + axis_label
    );

    terms: list[Term] = [];
    constant = 0.0;

    if k == LayoutRelationKind.LEFT_OF {
        terms = [_t(s.right), _t(tgt.left, -1.0)];
        constant = -gap;
    } elif k == LayoutRelationKind.RIGHT_OF {
        terms = [_t(s.left), _t(tgt.right, -1.0)];
        constant = gap;
    } elif k == LayoutRelationKind.ABOVE {
        terms = [_t(s.bottom), _t(tgt.top, -1.0)];
        constant = -gap;
    } elif k == LayoutRelationKind.BELOW {
        terms = [_t(s.top), _t(tgt.bottom, -1.0)];
        constant = gap;
    } elif k == LayoutRelationKind.ALIGN_START {
        if horizontal_axis {
            terms = [_t(s.left), _t(tgt.left, -1.0)];
        } else {
            terms = [_t(s.top), _t(tgt.top, -1.0)];
        }
    } elif k == LayoutRelationKind.ALIGN_END {
        if horizontal_axis {
            terms = [_t(s.right), _t(tgt.right, -1.0)];
        } else {
            terms = [_t(s.bottom), _t(tgt.bottom, -1.0)];
        }
    } elif k == LayoutRelationKind.ALIGN_CENTER {
        if horizontal_axis {
            terms = [
                _t(s.left), _t(s.right),
                _t(tgt.left, -1.0), _t(tgt.right, -1.0),
            ];
        } else {
            terms = [
                _t(s.top), _t(s.bottom),
                _t(tgt.top, -1.0), _t(tgt.bottom, -1.0),
            ];
        }
    } else {
        # SAME_SIZE
        if horizontal_axis {
            terms = [
                _t(s.right), _t(s.left, -1.0),
                _t(tgt.right, -1.0), _t(tgt.left, 1.0),
            ];
        } else {
            terms = [
                _t(s.bottom), _t(s.top, -1.0),
                _t(tgt.bottom, -1.0), _t(tgt.top, 1.0),
            ];
        }
    }

    return _emit(
        result, _expr(terms, constant), Relation.EQ, rel.strength, prov
    );
}


# ----------------------------------------------------------------------
# Entry point.
# ----------------------------------------------------------------------

"""Compile the detached tree rooted at layout_root plus its Screen-owned
overlays into solver constraints (LAYOUT-ENGINE-PLAN §6).

`natural_sizes` maps node id -> measured Size for INTRINSIC/BOUNDED weak
preferences; absent entries simply skip the weak preference until M5
wires measurement in front of compilation."""
def compile_layout(
    state: LayoutState,
    layout_root: UiNode,
    viewport: Viewport,
    natural_sizes: dict[str, Size] = {},
) -> CompileResult {
    scope = _collect_scope(layout_root);
    if scope.error is not None {
        r = CompileResult(ok=False);
        r.diagnostics.append(scope.error);
        return r;
    }

    # Spec liveness for every scoped node.
    missing: list[str] = [];
    for scoped in scope.order {
        if scoped.id_str not in state.specs {
            missing.append(scoped.id_str);
        }
    }
    if missing {
        r = CompileResult(ok=False);
        r.diagnostics.append(LayoutDiagnostic(
            code=LayoutError.INVALID_SPEC,
            severity=LayoutSeverity.ERROR,
            message="scoped nodes missing LayoutSpec registration",
            node_ids=missing,
        ));
        return r;
    }

    # Relation scope + ownership (owner must be the direct Child parent
    # of both endpoints, plan §6).
    scope_ids: dict[str, bool] = {};
    for scoped in scope.order {
        scope_ids[scoped.id_str] = True;
    }
    for rid in sorted(state.relations.keys()) {
        rel = state.relations[rid];
        for endpoint in [rel.source_id, rel.target_id] {
            if endpoint not in scope_ids {
                r = CompileResult(ok=False);
                r.diagnostics.append(LayoutDiagnostic(
                    code=LayoutError.OUT_OF_SCOPE,
                    severity=LayoutSeverity.ERROR,
                    message="relation endpoint outside compiled scope",
                    node_ids=[endpoint],
                ));
                return r;
            }
        }
        if (
            scope.parent_of.get(rel.source_id) != rel.owner_id
            or scope.parent_of.get(rel.target_id) != rel.owner_id
        ) {
            r = CompileResult(ok=False);
            r.diagnostics.append(LayoutDiagnostic(
                code=LayoutError.INVALID_TOPOLOGY,
                severity=LayoutSeverity.ERROR,
                message="relation owner is not the direct Child parent "
                        "of both endpoints",
                node_ids=[rel.source_id, rel.target_id],
            ));
            return r;
        }
    }

    solver = Solver();
    result = CompileResult(ok=True, solver=solver);

    # Deterministic variable allocation in traversal order.
    entries_by_id: dict[str, _Entry] = {};
    for scoped in scope.order {
        edges = NodeEdges(
            id_str=scoped.id_str,
            key=scoped.key,
            left=solver.new_variable(),
            top=solver.new_variable(),
            right=solver.new_variable(),
            bottom=solver.new_variable(),
        );
        result.nodes[scoped.id_str] = edges;
        entry = _Entry(scoped=scoped, edges=edges, spec=state.specs[scoped.id_str]);
        entries_by_id[scoped.id_str] = entry;
    }
    root_entry = entries_by_id[node_id(layout_root)];

    # Root pins + per-node geometric invariants.
    if not _emit_root(result, root_entry.edges, viewport) {
        result.solver = None;
        return result;
    }
    for scoped in scope.order {
        if not _emit_invariants(result, result.nodes[scoped.id_str]) {
            result.solver = None;
            return result;
        }
    }

    # Top-down continuous partition emission from the root.
    if not _emit_partition(
        result,
        root_entry,
        entries_by_id,
        natural_sizes,
        float(viewport.columns),
        float(viewport.rows),
    ) {
        result.solver = None;
        return result;
    }

    # Overlays: out-of-flow sizing and anchoring against the root box,
    # then partition emission for their own subtrees. An overlay's
    # provisional span is its FIXED size where declared, else the root
    # viewport span (M5 threads real solved spans here).
    for scoped in scope.order {
        if not scoped.is_overlay {
            continue;
        }
        ov_entry = entries_by_id[scoped.id_str];
        if not _emit_overlay(
            result,
            ov_entry,
            root_entry.edges,
            natural_sizes,
        ) {
            result.solver = None;
            return result;
        }
        if isinstance(scoped.target, UiContainer) {
            ov_w = float(viewport.columns);
            ov_h = float(viewport.rows);
            if ov_entry.spec.width.mode == SizeMode.FIXED {
                ov_w = _req(ov_entry.spec.width.preferred);
            }
            if ov_entry.spec.height.mode == SizeMode.FIXED {
                ov_h = _req(ov_entry.spec.height.preferred);
            }
            if not _emit_partition(
                result,
                ov_entry,
                entries_by_id,
                natural_sizes,
                ov_w,
                ov_h,
            ) {
                result.solver = None;
                return result;
            }
        }
    }

    # Registered spatial relations, ascending handle order.
    for rid in sorted(state.relations.keys()) {
        rel = state.relations[rid];
        if not _emit_relation(result, rid, rel, result.nodes) {
            result.solver = None;
            return result;
        }
    }
    return result;
}
