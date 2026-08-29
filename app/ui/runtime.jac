"""UiSession runtime: detached graph ownership, focus, bindings, and disposal.

The view graph lives under UiSessionRoot and is never attached to Jac's
persistent root. Renderer geometry and capability tables are session-local
side tables keyed by jid(node).
"""

import from ui.model {
    UiNode,
    UiContainer,
    UiSessionRoot,
    Screen,
    Overlay,
    Child,
    Feeds,
    FocusNext,
    Layer,
    Owns,
    node_id,
    ordered_children,
}

import from ui.mutation {
    append_child,
    dispose_subtree,
    MutationResult,
}

import from ui.bindings {
    BindingRegistry,
    clear_bindings,
    find_orphan_bindings,
    is_empty,
}


obj RendererState {
    has layout: dict[str, dict[str, int]] = {};
    has damage: list[dict[str, int]] = [];
    has cursor_holder_id: str = "";
}


obj CapabilityRegistry {
    has by_node: dict[str, list[str]] = {};
}


obj InvalidationRecord {
    has node_id: str,
        layout_root_id: str,
        reason: str;
}


"""Queued UI session event (resize, ...) for consumers to drain."""
obj SessionEventRecord {
    has kind: str = "";
    has payload: dict[str, int] = {};
}


obj UiSession {
    has bindings: BindingRegistry;
    has renderer: RendererState;
    has capabilities: CapabilityRegistry;
    has ui_root: UiSessionRoot | None = None;
    has current_screen: Screen | None = None;
    has focus_id: str = "";
    has saved_focus_id: str = "";
    has graph_revision: int = 0;
    has disposed: bool = False;
    has invalidation_journal: list[InvalidationRecord] = [];
    has event_queue: list[SessionEventRecord] = [];
    has tracked_node_ids: set[str] = set();
}


obj SessionLeak {
    has kind: str,
        detail: str;
}


obj UiSessionHandle {
    has session: UiSession;
    has ui_root_id: str;
}


def create_session() -> UiSessionHandle {
    ui_root = UiSessionRoot(key="session");
    session = UiSession(
        ui_root=ui_root,
        bindings=BindingRegistry(),
        renderer=RendererState(),
        capabilities=CapabilityRegistry(),
    );
    track_node(session, ui_root);
    return UiSessionHandle(session=session, ui_root_id=node_id(ui_root));
}


def track_node(session: UiSession, n: UiNode) {
    session.tracked_node_ids.add(node_id(n));
}


def is_reachable_from_root(session: UiSession, n: UiNode) -> bool {
    if session.disposed or session.ui_root is None {
        return False;
    }
    current: UiNode | None = n;
    while current is not None {
        if current is session.ui_root {
            return True;
        }
        parents = [current <-:Child:<-];
        if not parents {
            return False;
        }
        current = parents[0];
    }
    return False;
}


def assert_mutation_parent(session: UiSession, parent: UiContainer) {
    if session.disposed {
        raise ValueError("UiSession is disposed");
    }
    if not is_reachable_from_root(session, parent) {
        raise ValueError(
            "Mutation parent is not reachable from UiSessionRoot: "
            + parent.key
        );
    }
}


def append_child_session(
    session: UiSession,
    parent: UiContainer,
    child: UiNode,
) -> MutationResult {
    assert_mutation_parent(session, parent);
    result = append_child(parent, child);
    track_node(session, child);
    session.graph_revision += result.graph_revision;
    if result.layout_root_id {
        record_invalidation(
            session,
            node_id(child),
            result.layout_root_id,
            "append_child",
        );
    }
    return result;
}


def set_current_screen(session: UiSession, screen: Screen) {
    session.current_screen = screen;
    track_node(session, screen);
}


def set_focus(session: UiSession, n: UiNode | None) {
    if n is None {
        session.focus_id = "";
        return;
    }
    session.focus_id = node_id(n);
}


def register_capability(session: UiSession, node_id_str: str, cap_name: str) {
    if node_id_str not in session.capabilities.by_node {
        session.capabilities.by_node[node_id_str] = [];
    }
    session.capabilities.by_node[node_id_str].append(cap_name);
}


def release_capabilities(session: UiSession, node_id_str: str) {
    if node_id_str in session.capabilities.by_node {
        del session.capabilities.by_node[node_id_str];
    }
}


def record_invalidation(
    session: UiSession,
    node_id_str: str,
    layout_root_id: str,
    reason: str,
) {
    session.invalidation_journal.append(
        InvalidationRecord(
            node_id=node_id_str,
            layout_root_id=layout_root_id,
            reason=reason,
        )
    );
}


"""BFS from Jac persistent root across all edge types; return UI jids found."""
def ui_jids_reachable_from_persistent_root(ui_jids: set[str]) -> list[str] {
    found: list[str] = [];
    visited: set[str] = set();
    # Seed via append: an any-typed list literal (`= [root]`) does not lower
    # natively, while append onto an explicitly typed list does.
    queue: list[any] = [];
    queue.append(root);
    while queue {
        current = queue.pop(0);
        current_jid = jid(current);
        if current_jid in ui_jids {
            found.append(current_jid);
        }
        for neighbor in [current -->] {
            nj = jid(neighbor);
            if nj not in visited {
                visited.add(nj);
                queue.append(neighbor);
            }
        }
        for neighbor in [current <--] {
            nj = jid(neighbor);
            if nj not in visited {
                visited.add(nj);
                queue.append(neighbor);
            }
        }
    }
    return found;
}


def _endpoint_tracked(session: UiSession, n: UiNode) -> bool {
    return node_id(n) in session.tracked_node_ids;
}


def _collect_stale_edges(session: UiSession) -> list[str] {
    stale: list[str] = [];
    if session.ui_root is None {
        return stale;
    }
    stack: list[UiNode] = [session.ui_root];
    while stack {
        current = stack.pop();
        if isinstance(current, UiContainer) {
            for child in ordered_children(current) {
                if not _endpoint_tracked(session, child) {
                    stale.append(
                        "Child:"
                        + node_id(current)
                        + "->"
                        + node_id(child)
                    );
                }
                stack.append(child);
            }
        }
        for target in [current ->:Owns:->] {
            if not _endpoint_tracked(session, target) {
                stale.append("Owns:" + node_id(current) + "->" + node_id(target));
            }
        }
        for target in [current ->:Feeds:->] {
            if not _endpoint_tracked(session, target) {
                stale.append("Feeds:" + node_id(current) + "->" + node_id(target));
            }
        }
        for target in [current ->:FocusNext:->] {
            if not _endpoint_tracked(session, target) {
                stale.append(
                    "FocusNext:" + node_id(current) + "->" + node_id(target)
                );
            }
        }
        for target in [current ->:Layer:->] {
            if not _endpoint_tracked(session, target) {
                stale.append("Layer:" + node_id(current) + "->" + node_id(target));
            }
        }
    }
    return stale;
}


def _find_node_by_jid(n: UiNode, target_jid: str) -> UiNode | None {
    if node_id(n) == target_jid {
        return n;
    }
    if isinstance(n, UiContainer) {
        for child in ordered_children(n) {
            found = _find_node_by_jid(child, target_jid);
            if found is not None {
                return found;
            }
        }
    }
    return None;
}


def validate_session(session: UiSession) -> list[SessionLeak] {
    if session.disposed {
        return [];
    }
    leaks: list[SessionLeak] = [];
    for binding in find_orphan_bindings(
        session.bindings,
        session.tracked_node_ids,
    ) {
        leaks.append(
            SessionLeak(
                kind="orphan_binding",
                detail=binding.target_id,
            )
        );
    }
    if session.focus_id and session.focus_id not in session.tracked_node_ids {
        leaks.append(
            SessionLeak(
                kind="invalid_focus",
                detail=session.focus_id,
            )
        );
    }
    for cap_node_id in session.capabilities.by_node {
        if cap_node_id not in session.tracked_node_ids {
            leaks.append(
                SessionLeak(
                    kind="unreleased_capability",
                    detail=cap_node_id,
                )
            );
        }
    }
    for layout_id in session.renderer.layout {
        if layout_id not in session.tracked_node_ids {
            leaks.append(
                SessionLeak(
                    kind="stale_renderer_layout",
                    detail=layout_id,
                )
            );
        }
    }
    for edge_detail in _collect_stale_edges(session) {
        leaks.append(
            SessionLeak(
                kind="stale_edge",
                detail=edge_detail,
            )
        );
    }
    return leaks;
}


def dispose_session(session: UiSession) {
    if session.disposed {
        return;
    }
    session.disposed = True;
    clear_bindings(session.bindings);
    session.capabilities.by_node = {};
    session.renderer.layout = {};
    session.renderer.damage = [];
    session.renderer.cursor_holder_id = "";
    session.event_queue = [];
    session.invalidation_journal = [];
    session.focus_id = "";
    session.saved_focus_id = "";
    session.current_screen = None;
    if session.ui_root is not None {
        dispose_subtree(session.ui_root);
        session.ui_root = None;
    }
    session.tracked_node_ids.clear();
}


def get_focus_node(session: UiSession) -> UiNode | None {
    if session.disposed or session.ui_root is None or not session.focus_id {
        return None;
    }
    if session.focus_id not in session.tracked_node_ids {
        return None;
    }
    return _find_node_by_jid(session.ui_root, session.focus_id);
}


"""Unit 7 — focus order, layer z-order, and modal overlay lifecycle."""


obj OverlayBounds {
    has x: int = 0,
        y: int = 0,
        width: int = 0,
        height: int = 0;

    def is_empty() -> bool {
        return self.width <= 0 or self.height <= 0;
    }
}


obj OverlayOpenResult {
    has overlay_id: str,
        saved_focus_id: str,
        initial_focus_id: str;
}


obj OverlayCloseResult {
    has restored_focus_id: str,
        damage: OverlayBounds,
        overlay_id: str;
}


obj RankedOverlay {
    has z_index: int,
        overlay: Overlay;
}


def _layer_z(screen: Screen, overlay: Overlay) -> int {
    for layer_edge in [edge screen ->:Layer:-> overlay] {
        return layer_edge.z_index;
    }
    return 0;
}


def _ranked_overlay_asc(pair: RankedOverlay) -> int {
    return pair.z_index;
}


def _ranked_overlay_desc(pair: RankedOverlay) -> int {
    return -pair.z_index;
}


def _layer_pairs(screen: Screen) -> list[RankedOverlay] {
    pairs: list[RankedOverlay] = [];
    for candidate in [screen ->:Layer:->] {
        if isinstance(candidate, Overlay) {
            pairs.append(
                RankedOverlay(
                    z_index=_layer_z(screen, candidate),
                    overlay=candidate,
                )
            );
        }
    }
    return pairs;
}


"""Paint order: ascending z_index (OSPUI.md §17)."""
def layers_paint_order(screen: Screen) -> list[Overlay] {
    pairs = _layer_pairs(screen);
    pairs.sort(key=_ranked_overlay_asc);
    return [p.overlay for p in pairs];
}


"""Input targeting order: descending z_index (OSPUI.md §17)."""
def layers_input_order(screen: Screen) -> list[Overlay] {
    pairs = _layer_pairs(screen);
    pairs.sort(key=_ranked_overlay_desc);
    return [p.overlay for p in pairs];
}


def _collect_focusable(n: UiNode) -> list[UiNode] {
    out: list[UiNode] = [];
    if isinstance(n, Overlay) {
        out.append(n);
    } elif not isinstance(n, UiContainer) {
        # UiRegion and other leaf semantic nodes.
        out.append(n);
    }
    if isinstance(n, UiContainer) {
        for child in ordered_children(n) {
            for leaf in _collect_focusable(child) {
                out.append(leaf);
            }
        }
    }
    return out;
}


def _collect_subtree_ids(n: UiNode) -> list[str] {
    ids: list[str] = [node_id(n)];
    if isinstance(n, UiContainer) {
        for child in ordered_children(n) {
            for sid in _collect_subtree_ids(child) {
                ids.append(sid);
            }
        }
    }
    return ids;
}


"""Ordered focusable nodes under screen: containment walk + FocusNext overrides."""
def focus_order(session: UiSession, screen: Screen) -> list[UiNode] {
    _ = session;
    structural = _collect_focusable(screen);
    if not structural {
        return [];
    }
    ordered: list[UiNode] = [];
    visited: set[str] = set();
    for n in structural {
        nid = node_id(n);
        if nid in visited {
            continue;
        }
        current: UiNode | None = n;
        while current is not None {
            cid = node_id(current);
            if cid in visited {
                break;
            }
            ordered.append(current);
            visited.add(cid);
            nxts = [current ->:FocusNext:->];
            if not nxts {
                break;
            }
            current = nxts[0];
        }
    }
    return ordered;
}


"""Advance focus along focus_order, honoring FocusNext overrides."""
def advance_focus(
    session: UiSession,
    direction: str = "next",
) -> UiNode | None {
    screen = session.current_screen;
    if screen is None {
        return None;
    }
    order = focus_order(session, screen);
    if not order {
        return None;
    }
    focused = get_focus_node(session);
    if focused is None {
        set_focus(session, order[0]);
        return order[0];
    }
    idx = 0;
    found = -1;
    for (i, n) in enumerate(order) {
        if n is focused {
            found = i;
            break;
        }
    }
    if found >= 0 {
        idx = found;
    }
    if direction == "prev" {
        idx = (idx - 1) % len(order);
    } else {
        idx = (idx + 1) % len(order);
    }
    target = order[idx];
    set_focus(session, target);
    return target;
}


"""Open a modal overlay: Layer edge, save focus, trap input, focus initial."""
def open_modal_overlay(
    session: UiSession,
    screen: Screen,
    overlay: Overlay,
    initial_focus: UiNode | None = None,
    z_index: int = 10,
) -> OverlayOpenResult {
    saved = session.focus_id;
    existing = False;
    for _cand in [screen ->:Layer:-> overlay] {
        existing = True;
    }
    if existing {
        for layer_edge in [edge screen ->:Layer:-> overlay] {
            layer_edge.z_index = z_index;
            layer_edge.modal = True;
        }
    } else {
        screen +>:Layer(z_index=z_index, modal=True):+> overlay;
    }
    track_node(session, overlay);
    if isinstance(overlay, UiContainer) {
        for child in ordered_children(overlay) {
            track_node(session, child);
        }
    }
    session.saved_focus_id = saved;
    target = overlay if initial_focus is None else initial_focus;
    track_node(session, target);
    set_focus(session, target);
    return OverlayOpenResult(
        overlay_id=node_id(overlay),
        saved_focus_id=saved,
        initial_focus_id=node_id(target),
    );
}


"""Close overlay: dispose subtree, restore focus, report damage bounds."""
def close_overlay(
    session: UiSession,
    overlay: Overlay,
) -> OverlayCloseResult {
    overlay_id = node_id(overlay);
    damage = OverlayBounds(x=0, y=0, width=0, height=0);
    layout_entry = session.renderer.layout.get(overlay_id);
    if layout_entry is not None {
        x = int(layout_entry.get("x", 0));
        y = int(layout_entry.get("y", 0));
        w = int(layout_entry.get("width", 0));
        h = int(layout_entry.get("height", 0));
        damage = OverlayBounds(x=x, y=y, width=w, height=h);
    }

    subtree_ids = _collect_subtree_ids(overlay);

    restored = "";
    saved = session.saved_focus_id;
    session.saved_focus_id = "";
    if saved and saved in session.tracked_node_ids and saved not in subtree_ids {
        session.focus_id = saved;
        restored = saved;
    } else {
        session.focus_id = "";
    }

    for parent in list([overlay <-:Layer:<-]) {
        for e in [edge parent ->:Layer:-> overlay] {
            del e;
        }
    }
    dispose_subtree(overlay);
    for sid in subtree_ids {
        if sid in session.tracked_node_ids {
            session.tracked_node_ids.remove(sid);
        }
        release_capabilities(session, sid);
        if sid in session.renderer.layout {
            del session.renderer.layout[sid];
        }
    }
    session.graph_revision += 1;
    return OverlayCloseResult(
        restored_focus_id=restored,
        damage=damage,
        overlay_id=overlay_id,
    );
}
