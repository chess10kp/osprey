"""Inspection and invariant surface for the OSP UI (OSPUI.md §20).

Dumps read semantic graph + runtime side tables. Renderer state is never
implied to live on graph nodes.
"""

import from ui.model {
    UiNode,
    UiContainer,
    Screen,
    Overlay,
    node_id,
    ordered_children,
}

import from ui.runtime {
    UiSession,
}


obj InspectFinding {
    has kind: str,
        detail: str;
}


obj InvalidationExplanation {
    has node_id: str,
        origin: str,
        layout_root_id: str,
        damage_reason: str;
}


"""Deterministic dump of semantic UI nodes and typed edges.

Unit 11 implementation fills this in. Stub raises until then.
"""
def dump_graph(session: UiSession) -> str {
    _ = session;
    raise NotImplementedError("Unit 11: dump_graph");
}


"""Dump domain source → UI target bindings.

Unit 11 implementation fills this in. Stub raises until then.
"""
def dump_bindings(session: UiSession) -> str {
    _ = session;
    raise NotImplementedError("Unit 11: dump_bindings");
}


"""Dump target, bubble path, and handled/stopped/default flags for an event.

Unit 11 implementation fills this in. Stub raises until then.
"""
def dump_event_path(
    session: UiSession,
    event: any,
    target: UiNode | None = None,
) -> str {
    _ = (session, event, target);
    raise NotImplementedError("Unit 11: dump_event_path");
}


"""Explain invalidation: originating event/feed → layout root → damage.

Unit 11 implementation fills this in. Stub raises until then.
"""
def explain_invalidation(
    session: UiSession,
    n: UiNode,
) -> InvalidationExplanation {
    _ = (session, n);
    raise NotImplementedError("Unit 11: explain_invalidation");
}


"""Dump layout contract, measured size, rect, and clip for a node.

Unit 11 implementation fills this in. Stub raises until then.
"""
def dump_layout(session: UiSession, n: UiNode) -> str {
    _ = (session, n);
    raise NotImplementedError("Unit 11: dump_layout");
}


"""Dump frame damage: old/new bounds and repaint reasons.

Unit 11 implementation fills this in. Stub raises until then.
"""
def dump_damage(session: UiSession, frame: any = None) -> str {
    _ = (session, frame);
    raise NotImplementedError("Unit 11: dump_damage");
}


"""Dump containment, ownership, bindings, and capabilities for a node.

Unit 11 implementation fills this in. Stub raises until then.
"""
def dump_lifetimes(session: UiSession, n: UiNode) -> str {
    _ = (session, n);
    raise NotImplementedError("Unit 11: dump_lifetimes");
}


"""Validate cycles, duplicate keys, invalid ranks, stale edges, invalid focus.

Returns findings; empty list means healthy. Unit 11 implementation fills this
in beyond what validate_session already covers.
"""
def validate_invariants(session: UiSession) -> list[InspectFinding] {
    _ = session;
    raise NotImplementedError("Unit 11: validate_invariants");
}
