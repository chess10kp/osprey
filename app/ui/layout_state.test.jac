"""Behavior tests for the permanent layout registry (LAYOUT-ENGINE-PLAN §4,
M4): spec validation, relation lifecycle, content revisions, and clearing.

The same-stem base module ui/layout_state.jac hosts the lifecycle functions
until the M6 cutover consolidates them into ui.layout.
"""

import from constraints.algebra {
    StrengthTier,
}
import from ui.layout {
    Axis,
    MutationResult,
    AxisSize,
    LayoutError,
    LayoutRelation,
    LayoutRelationKind,
    SizeMode,
    Viewport,
}
import from ui.model {
    Header,
    Prompt,
    Status,
    TranscriptView,
    node_id,
}


def _fixed(n: float) -> AxisSize {
    return AxisSize(mode=SizeMode.FIXED, preferred=n);
}


def _intrinsic() -> AxisSize {
    return AxisSize(mode=SizeMode.INTRINSIC);
}


def _spec(width: AxisSize = _fixed(40), height: AxisSize = _fixed(3)) -> LayoutSpec {
    return LayoutSpec(width=width, height=height);
}


def _must_handle(r: MutationResult) -> RelationHandle {
    assert r.relation_handle is not None;
    return r.relation_handle;
}


def _rel(
    owner: str,
    source: str,
    target: str,
    kind: LayoutRelationKind,
    axis: Axis,
) -> LayoutRelation {
    return LayoutRelation(
        owner_id=owner,
        source_id=source,
        target_id=target,
        kind=kind,
        axis=axis,
        provenance="test",
    );
}


test "set_spec registers a validated spec by stable node id" {
    state = create_layout_state(100, 40);
    assert state.viewport.columns == 100;
    prompt = Prompt(key="p");
    r = set_spec(state, prompt, _spec());
    assert r.ok;
    assert node_id(prompt) in state.specs;

    # Replacing the spec is allowed; last write wins.
    r2 = set_spec(state, prompt, _spec(height=_fixed(5)));
    assert r2.ok;
    assert state.specs[node_id(prompt)].height.preferred == 5.0;
}


test "set_spec rejects malformed specs with INVALID_SPEC" {
    state = create_layout_state();
    status = Status(key="s");

    cases: list[LayoutSpec] = [
        # Negative minimum.
        _spec(width=AxisSize(mode=SizeMode.BOUNDED, minimum=-1.0)),
        # minimum > maximum.
        _spec(width=AxisSize(
            mode=SizeMode.BOUNDED,
            minimum=10.0,
            maximum=5.0,
        )),
        # FIXED without preferred.
        _spec(width=AxisSize(mode=SizeMode.FIXED)),
        # GROW with zero weight.
        _spec(width=AxisSize(mode=SizeMode.GROW, grow_weight=0.0)),
    ];
    for bad in cases {
        r = set_spec(state, status, bad);
        assert not r.ok;
        assert len(r.diagnostics) == 1;
        assert r.diagnostics[0].code == LayoutError.INVALID_SPEC;
    }
    assert len(state.specs) == 0;
}


test "add_relation validates liveness, shape, and gap rules" {
    state = create_layout_state();
    header = Header(key="h");
    transcript = TranscriptView(key="t");
    set_spec(state, header, _spec());
    set_spec(state, transcript, _spec());

    # Unregistered endpoints are stale.
    ghost = _rel(node_id(header), node_id(transcript), "ghost",
                 LayoutRelationKind.LEFT_OF, Axis.HORIZONTAL);
    r0 = add_relation(state, ghost);
    assert not r0.ok;
    assert r0.diagnostics[0].code == LayoutError.STALE_NODE;
    assert r0.diagnostics[0].node_ids == ["ghost"];

    # Directional kind on the wrong axis.
    wrong_axis = _rel(node_id(header), node_id(header), node_id(transcript),
                      LayoutRelationKind.LEFT_OF, Axis.VERTICAL);
    r1 = add_relation(state, wrong_axis);
    assert not r1.ok;
    assert r1.diagnostics[0].code == LayoutError.INVALID_RELATION;

    # Negative gap.
    neg_gap = _rel(node_id(header), node_id(header), node_id(transcript),
                   LayoutRelationKind.LEFT_OF, Axis.HORIZONTAL);
    neg_gap.gap = -1.0;
    r2 = add_relation(state, neg_gap);
    assert not r2.ok;
    assert r2.diagnostics[0].code == LayoutError.INVALID_RELATION;

    # Alignment kind with nonzero gap.
    aligned = _rel(node_id(header), node_id(header), node_id(transcript),
                   LayoutRelationKind.ALIGN_START, Axis.HORIZONTAL);
    aligned.gap = 2.0;
    r3 = add_relation(state, aligned);
    assert not r3.ok;
    assert r3.diagnostics[0].code == LayoutError.INVALID_RELATION;

    # Happy path allocates deterministic ascending handles.
    good = _rel(node_id(header), node_id(header), node_id(transcript),
                LayoutRelationKind.ALIGN_START, Axis.HORIZONTAL);
    r4 = add_relation(state, good);
    assert r4.ok;
    assert r4.relation_handle is not None;
    assert r4.relation_handle.id == 1;
    assert len(state.relations) == 1;
}


test "duplicate relations merge provenance or reject strength change" {
    state = create_layout_state();
    a = Header(key="a");
    b = TranscriptView(key="b");
    set_spec(state, a, _spec());
    set_spec(state, b, _spec());

    first = _rel(node_id(a), node_id(a), node_id(b),
                 LayoutRelationKind.SAME_SIZE, Axis.HORIZONTAL);
    first.provenance = "shell:header";
    r1 = add_relation(state, first);
    assert r1.ok;

    second = _rel(node_id(a), node_id(a), node_id(b),
                  LayoutRelationKind.SAME_SIZE, Axis.HORIZONTAL);
    second.provenance = "gate:duplicate";
    r2 = add_relation(state, second);
    assert r2.ok;
    # Merged into one stored relation carrying both provenances.
    assert len(state.relations) == 1;
    merged = state.relations[_must_handle(r1).id];
    assert merged.provenance == "shell:header;gate:duplicate";

    # Same expression, different strength -> rejected.
    third = _rel(node_id(a), node_id(a), node_id(b),
                 LayoutRelationKind.SAME_SIZE, Axis.HORIZONTAL);
    third.strength = StrengthTier.STRONG;
    third.provenance = "gate:conflict";
    r3 = add_relation(state, third);
    assert not r3.ok;
    assert r3.diagnostics[0].code == LayoutError.INVALID_RELATION;
}


test "remove_relation drops exactly its handle" {
    state = create_layout_state();
    a = Header(key="a");
    b = TranscriptView(key="b");
    set_spec(state, a, _spec());
    set_spec(state, b, _spec());

    missing = remove_relation(state, RelationHandle(id=99));
    assert not missing.ok;

    rel = _rel(node_id(a), node_id(a), node_id(b),
               LayoutRelationKind.ABOVE, Axis.VERTICAL);
    r = add_relation(state, rel);
    assert r.ok;
    handle = _must_handle(r);
    assert remove_relation(state, handle).ok;
    assert len(state.relations) == 0;
    assert not remove_relation(state, handle).ok;
}


test "set_content enforces monotonic revisions and liveness" {
    state = create_layout_state();
    t = TranscriptView(key="t");
    set_spec(state, t, _spec());

    ghost = set_content(state, Status(key="nope"), ["x"], 1);
    assert not ghost.ok;
    assert ghost.diagnostics[0].code == LayoutError.STALE_NODE;

    assert set_content(state, t, ["one"], 1).ok;
    # Decreasing either revision is rejected.
    assert not set_content(state, t, ["two"], 0).ok;
    assert not set_content(state, t, ["two"], 1, style_revision=-1).ok;
    # Equal-or-advancing revisions replace content.
    assert set_content(state, t, ["two"], 1).ok;
    assert set_content(state, t, ["three"], 2).ok;
    entry = state.content[node_id(t)];
    assert entry.lines == ["three"];
    assert entry.content_revision == 2;
}


test "clear_node removes spec, content, and incident relations atomically" {
    state = create_layout_state();
    owner_node = Header(key="owner");
    left = TranscriptView(key="left");
    right = Status(key="right");
    set_spec(state, owner_node, _spec());
    set_spec(state, left, _spec());
    set_spec(state, right, _spec());
    assert set_content(state, left, ["l"], 1).ok;

    # left --ABOVE--> right (owned by root), and left --SAME_SIZE--> root.
    r1 = add_relation(state, _rel(
        node_id(owner_node), node_id(left), node_id(right),
        LayoutRelationKind.ABOVE, Axis.VERTICAL,
    ));
    r2 = add_relation(state, _rel(
        node_id(owner_node), node_id(left), node_id(owner_node),
        LayoutRelationKind.SAME_SIZE, Axis.HORIZONTAL,
    ));
    assert r1.ok and r2.ok;
    assert len(state.relations) == 2;

    assert clear_node(state, left).ok;
    assert node_id(left) not in state.specs;
    assert node_id(left) not in state.content;
    assert len(state.relations) == 0;
    # Untouched nodes survive.
    assert node_id(owner_node) in state.specs;
    assert node_id(right) in state.specs;
}


test "frame accessors are None before first publication" {
    state = create_layout_state();
    p = Prompt(key="p");
    set_spec(state, p, _spec());
    assert frame_entry_of(state, p) is None;
    assert rect_of(state, p) is None;
}
