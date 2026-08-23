"""Retained terminal renderer: damage, cell diff, cursor, ANSI paint.

Queries OSP topology and layout side tables. Emits one synchronized ANSI
update per frame. Damage is the union of old and new rectangles
(OSPUI.md §15.4–15.6). Full-screen clears must not hide damage bugs —
FrameResult.used_full_clear and patch_rects exist so tests can assert
patch scope.
"""

import from ui.model {
    UiNode,
    UiContainer,
    Screen,
    Overlay,
    ordered_children,
    node_id,
}

import from ui.layout_types {
    FrameEntry,
    LayoutResult,
    LayoutSpec,
    LayoutState,
    Rect,
    Viewport,
    clear_node,
    create_layout_state,
    frame_entry_of,
    rect_union,
    set_content,
    set_spec,
}

import from ui.layout {
    compute_layout,
}

import from ui.terminal {
    Terminal,
    synchronized_write,
}

import from ui.cells {
    CellBuffer,
    StyleAttrs,
    StyledCell,
    create_buffer,
    buffer_clear_rect,
    buffer_blit_text,
    buffer_to_plain_rows,
    diff_buffers_ansi,
}


obj DamageRect {
    has rect: Rect = Rect(),
        reason: str = "";
}


obj FrameResult {
    has damage: list[DamageRect] = [],
        cells_written: int = 0,
        used_full_clear: bool = False,
        patch_rects: list[Rect] = [],
        cursor_row: int = -1,
        cursor_col: int = -1,
        cursor_visible: bool = False,
        sync_wrapped: bool = False;
}


obj AnsiDiff {
    has text: str = "",
        cells_written: int = 0;
}


obj _OverlayHit {
    has node: UiNode,
        z: int = 0,
        id_str: str = "";
}


obj CursorPos {
    has row: int = -1,
        col: int = -1;
}


obj Renderer {
    has layout: LayoutState,
        # Retained previous frame as styled cells (OSPUI §15.1).
        previous: CellBuffer | None = None,
        # Previous-frame rects per node id (replaces the legacy engine's
        # entry.prev_rect / snapshot_rects damage baseline).
        prev_rects: dict[str, Rect] = {},
        damage: list[DamageRect] = [],
        cursor_node_id: str = "",
        cursor_row_offset: int = 0,
        cursor_col_offset: int = 0,
        last_cursor_row: int = -1,
        last_cursor_col: int = -1,
        last_cursor_visible: bool = False,
        graph_revision: int = 0,
        # Monotonic per-node content revisions for set_content.
        content_revisions: dict[str, int] = {},
        # Node ids marked dirty before the next frame clears the flags.
        pending_semantic: set[str] = set(),
        pending_layout: set[str] = set();
}


def create_renderer(columns: int = 80, rows: int = 24) -> Renderer {
    return Renderer(layout=create_layout_state(columns, rows));
}


# The permanent seam has no contracts: callers install a LayoutSpec via
# set_spec (see screen.jac configure_main_shell_layout for the idiom).
def set_node_contract(renderer: Renderer, n: UiNode, spec: LayoutSpec) {
    set_spec(renderer.layout, n, spec);
}


# set_content requires monotonic revisions; keep the legacy three-arg
# surface by minting a per-node revision counter here.
def set_node_content(renderer: Renderer, n: UiNode, lines: list[str]) {
    nid = node_id(n);
    rev = renderer.content_revisions.get(nid, 0) + 1;
    renderer.content_revisions[nid] = rev;
    set_content(renderer.layout, n, lines, rev);
}


# No dirty tracking exists anymore — frames recompute wholesale; the
# pending sets only steer same-bounds semantic damage attribution.
def mark_semantic_dirty(renderer: Renderer, n: UiNode) {
    renderer.pending_semantic.add(node_id(n));
}


def mark_layout_dirty(renderer: Renderer, n: UiNode) {
    renderer.pending_layout.add(node_id(n));
}


def request_cursor(
    renderer: Renderer,
    n: UiNode,
    row_offset: int = 0,
    col_offset: int = 0,
) {
    renderer.cursor_node_id = node_id(n);
    renderer.cursor_row_offset = row_offset;
    renderer.cursor_col_offset = col_offset;
}


def clear_cursor(renderer: Renderer) {
    renderer.cursor_node_id = "";
    renderer.cursor_row_offset = 0;
    renderer.cursor_col_offset = 0;
}


"""Detach a node: damage its previous rect and drop registry state."""
def detach_node(renderer: Renderer, n: UiNode) {
    entry = frame_entry_of(renderer.layout, n);
    if entry is not None and not entry.rect.is_empty() {
        renderer.damage.append(
            DamageRect(rect=entry.rect.copy(), reason="detach")
        );
    }
    if renderer.cursor_node_id == node_id(n) {
        clear_cursor(renderer);
    }
    renderer.content_revisions.pop(node_id(n), None);
    clear_node(renderer.layout, n);
}


def _blank_buffer(columns: int, rows: int) -> CellBuffer {
    return create_buffer(columns, rows);
}


def _paint_text_into(
    buf: CellBuffer,
    text: str,
    row: int,
    col: int,
    max_width: int,
    attrs: StyleAttrs | None = None,
) {
    if max_width <= 0 {
        return;
    }
    buffer_blit_text(buf, row, col, text, attrs, max_width);
}


def _paint_entry_lines(
    buf: CellBuffer,
    layout_entry: FrameEntry,
    scrolls: bool,
) {
    rect = layout_entry.rect;
    clip = layout_entry.clip if not layout_entry.clip.is_empty() else rect;
    if clip.is_empty() or rect.is_empty() {
        return;
    }
    lines = layout_entry.wrapped_lines;
    scroll = 0;
    if scrolls {
        scroll = layout_entry.scroll_offset;
    }
    for vis_i in range(clip.height) {
        src_i = vis_i + scroll;
        term_row = clip.y + vis_i;
        if term_row < 0 or term_row >= buf.rows {
            continue;
        }
        buffer_clear_rect(buf, clip.x, term_row, clip.width, 1);
        if src_i < 0 or src_i >= len(lines) {
            continue;
        }
        _paint_text_into(
            buf,
            lines[src_i],
            term_row,
            clip.x,
            clip.width,
            None,
        );
    }
}


# Layer-reached overlays of one Screen, ordered by (z_index, jid) —
# same ordering the compiler's scope walk uses (plan §6.3).
def _overlay_z_key(hit: _OverlayHit) -> int {
    return hit.z;
}


def _overlay_jid_key(hit: _OverlayHit) -> str {
    return hit.id_str;
}


def _layered_overlays(layout_root: UiNode) -> list[UiNode] {
    found: list[_OverlayHit] = [];
    if isinstance(layout_root, Screen) {
        for ov in [layout_root ->:Layer:->] {
            z = 0;
            for e in [edge layout_root ->:Layer:-> ov] {
                z = e.z_index;
            }
            found.append(_OverlayHit(node=ov, z=z, id_str=node_id(ov)));
        }
    }
    if not found {
        return [];
    }
    found.sort(key=_overlay_jid_key);
    found.sort(key=_overlay_z_key);
    return [hit.node for hit in found];
}


def _paint_node(state: LayoutState, n: UiNode, buf: CellBuffer) {
    frame = state.last_frame;
    if frame is None {
        return;
    }
    nid = node_id(n);
    entry = frame.entries.get(nid);
    if entry is None {
        return;
    }
    if entry.wrapped_lines or nid in state.content {
        spec = state.specs.get(nid);
        scrolls = spec is not None and spec.scroll_vertical;
        _paint_entry_lines(buf, entry, scrolls);
    }
}


def _paint_tree(state: LayoutState, n: UiNode, buf: CellBuffer) {
    _paint_node(state, n, buf);
    if isinstance(n, UiContainer) {
        for child in ordered_children(n) {
            # Overlays hang off Layer edges; skip them in the flow walk so
            # a Child-mounted overlay is painted exactly once.
            if isinstance(child, Overlay) {
                continue;
            }
            _paint_tree(state, child, buf);
        }
    }
}


def _paint_frame_buffer(renderer: Renderer, layout_root: UiNode) -> CellBuffer {
    state = renderer.layout;
    buf = _blank_buffer(state.viewport.columns, state.viewport.rows);
    _paint_tree(state, layout_root, buf);
    for overlay in _layered_overlays(layout_root) {
        _paint_node(state, overlay, buf);
    }
    return buf;
}


def _rects_equal(a: Rect, b: Rect) -> bool {
    return (
        a.x == b.x
        and a.y == b.y
        and a.width == b.width
        and a.height == b.height
    );
}


def _walk_damage(
    renderer: Renderer,
    n: UiNode,
    out: list[DamageRect],
) {
    state = renderer.layout;
    frame = state.last_frame;
    nid = node_id(n);
    entry = frame.entries.get(nid) if frame is not None else None;
    prev = renderer.prev_rects.get(nid, Rect());
    if entry is not None {
        cur = entry.rect;
        if prev.is_empty() and not cur.is_empty() {
            out.append(DamageRect(rect=cur.copy(), reason="appear"));
        } elif not prev.is_empty() and cur.is_empty() {
            out.append(DamageRect(rect=prev.copy(), reason="disappear"));
        } elif not _rects_equal(prev, cur) {
            out.append(
                DamageRect(rect=rect_union(prev, cur), reason="bounds")
            );
        } elif (
            nid in renderer.pending_semantic or nid in renderer.pending_layout
        ) {
            if not cur.is_empty() {
                out.append(DamageRect(rect=cur.copy(), reason="semantic"));
            }
        }
    }
    if isinstance(n, UiContainer) {
        for child in ordered_children(n) {
            _walk_damage(renderer, child, out);
        }
        if isinstance(n, Screen) {
            for overlay in _layered_overlays(n) {
                _walk_damage(renderer, overlay, out);
            }
        }
    }
}


"""Compute damage rectangles from prev/current layout without painting."""
def compute_damage(renderer: Renderer, layout_root: UiNode) -> list[DamageRect] {
    out: list[DamageRect] = [];
    for d in renderer.damage {
        out.append(d);
    }
    _walk_damage(renderer, layout_root, out);
    if renderer.previous is None {
        out.append(
            DamageRect(
                rect=Rect(
                    x=0,
                    y=0,
                    width=renderer.layout.viewport.columns,
                    height=renderer.layout.viewport.rows,
                ),
                reason="first_frame",
            )
        );
    }
    return out;
}


def _merge_damage(damage: list[DamageRect]) -> list[Rect] {
    if not damage {
        return [];
    }
    merged = damage[0].rect.copy();
    for d in damage[1:] {
        merged = rect_union(merged, d.rect);
    }
    if merged.is_empty() {
        return [];
    }
    return [merged];
}


def _diff_ansi(
    previous: CellBuffer | None,
    desired: CellBuffer,
    patch_rects: list[Rect],
    columns: int,
    rows_n: int,
) -> AnsiDiff {
    _ = (columns, rows_n);
    diff = diff_buffers_ansi(previous, desired, patch_rects);
    return AnsiDiff(text=diff.text, cells_written=diff.cells_written);
}


def _resolve_cursor(renderer: Renderer) -> CursorPos {
    if not renderer.cursor_node_id {
        return CursorPos();
    }
    frame = renderer.layout.last_frame;
    entry = frame.entries.get(renderer.cursor_node_id) if frame is not None else None;
    if entry is None or entry.rect.is_empty() {
        return CursorPos();
    }
    row = entry.rect.y + renderer.cursor_row_offset;
    col = entry.rect.x + renderer.cursor_col_offset;
    if row < 0 or col < 0 {
        return CursorPos();
    }
    if row >= renderer.layout.viewport.rows or col >= renderer.layout.viewport.columns {
        return CursorPos();
    }
    return CursorPos(row=row, col=col);
}


"""Run the compute pipeline at the renderer's current viewport."""
def _run_layout(renderer: Renderer, layout_root: UiNode) -> LayoutResult {
    state = renderer.layout;
    vp = state.viewport;
    return compute_layout(
        state,
        layout_root,
        Viewport(columns=vp.columns, rows=vp.rows),
    );
}


# Replaces the legacy engine's snapshot_rects: record this frame's rects
# as the damage baseline for the next one.
def _snapshot_rects(renderer: Renderer) {
    fresh: dict[str, Rect] = {};
    frame = renderer.layout.last_frame;
    if frame is not None {
        for (nid, e) in frame.entries.items() {
            fresh[nid] = e.rect.copy();
        }
    }
    renderer.prev_rects = fresh;
}


"""Recompute the layout frame without painting (drivers/tests)."""
def relayout(renderer: Renderer, layout_root: UiNode) -> LayoutResult {
    return _run_layout(renderer, layout_root);
}


"""Materialize the desired full-frame cell rows without writing a terminal."""
def desired_cells(renderer: Renderer, layout_root: UiNode) -> list[str] {
    _run_layout(renderer, layout_root);
    buf = _paint_frame_buffer(renderer, layout_root);
    return buffer_to_plain_rows(buf);
}


"""Layout, damage, paint, and cursor for one frame."""
def render_frame(
    renderer: Renderer,
    layout_root: UiNode,
    term: Terminal,
) -> FrameResult {
    state = renderer.layout;
    cols = term.columns if term.columns > 0 else state.viewport.columns;
    rows_n = term.rows if term.rows > 0 else state.viewport.rows;
    state.viewport.columns = cols;
    state.viewport.rows = rows_n;

    _run_layout(renderer, layout_root);
    damage = compute_damage(renderer, layout_root);
    desired = _paint_frame_buffer(renderer, layout_root);
    patch_rects = _merge_damage(damage);
    diff = _diff_ansi(renderer.previous, desired, patch_rects, cols, rows_n);
    cursor = _resolve_cursor(renderer);
    cursor_visible = cursor.row >= 0 and cursor.col >= 0;
    ansi = diff.text;
    if cursor_visible {
        if not term.cursor_visible {
            term.show_cursor();
        }
        ansi = ansi + f"\x1b[{cursor.row + 1};{cursor.col + 1}H";
    } else {
        if term.cursor_visible {
            term.hide_cursor();
        }
    }
    synchronized_write(term, ansi);
    renderer.previous = desired;
    renderer.damage = [];
    renderer.pending_semantic = set();
    renderer.pending_layout = set();
    _snapshot_rects(renderer);
    renderer.last_cursor_row = cursor.row;
    renderer.last_cursor_col = cursor.col;
    renderer.last_cursor_visible = cursor_visible;
    return FrameResult(
        damage=damage,
        cells_written=diff.cells_written,
        used_full_clear=False,
        patch_rects=patch_rects,
        cursor_row=cursor.row,
        cursor_col=cursor.col,
        cursor_visible=cursor_visible,
        sync_wrapped=True,
    );
}


"""True if any emitted write contains a full-screen clear sequence."""
def frame_used_full_clear(writes: list[str]) -> bool {
    joined = "".join(writes);
    return "\x1b[2J" in joined or "\x1b[3J" in joined;
}


"""Sum of widths*heights for damage rects (upper bound on cells touched)."""
def damage_cell_count(damage: list[DamageRect]) -> int {
    total = 0;
    for d in damage {
        if not d.rect.is_empty() {
            total += d.rect.width * d.rect.height;
        }
    }
    return total;
}
