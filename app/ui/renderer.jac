"""Retained terminal renderer: damage, cell diff, cursor, ANSI paint.

Queries OSP topology and layout side tables. Emits one synchronized ANSI
update per frame. Damage is the union of old and new rectangles
(OSPUI.md §15.4–15.6). Full-screen clears must not hide damage bugs —
FrameResult.used_full_clear and patch_rects exist so tests can assert
patch scope.
"""

import from ui.model {
    UiNode,
    node_id,
}

import from ui.layout {
    LayoutTables,
    LayoutContract,
    Rect,
    Size,
    create_layout_tables,
    set_contract,
    set_content,
    get_entry,
    rect_of,
    measured_of,
    invalidate_semantic,
    invalidate_layout,
    clear_node,
    snapshot_rects,
    measure_and_arrange,
    rect_union,
}

import from ui.terminal {
    Terminal,
    synchronized_write,
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
        sync_wrapped: bool = False;
}


obj Renderer {
    has layout: LayoutTables,
        # Retained previous frame as row strings (display cells, no ANSI).
        previous: list[str] = [],
        damage: list[DamageRect] = [],
        cursor_node_id: str = "",
        cursor_row_offset: int = 0,
        cursor_col_offset: int = 0,
        last_cursor_row: int = -1,
        last_cursor_col: int = -1,
        graph_revision: int = 0;
}


def create_renderer(columns: int = 80, rows: int = 24) -> Renderer {
    return Renderer(layout=create_layout_tables(columns, rows));
}


def set_node_contract(renderer: Renderer, n: UiNode, contract: LayoutContract) {
    set_contract(renderer.layout, n, contract);
}


def set_node_content(renderer: Renderer, n: UiNode, lines: list[str]) {
    set_content(renderer.layout, n, lines);
}


def mark_semantic_dirty(renderer: Renderer, n: UiNode) {
    invalidate_semantic(renderer.layout, n);
}


def mark_layout_dirty(renderer: Renderer, n: UiNode) {
    invalidate_layout(renderer.layout, n);
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


"""Detach a node: damage its previous rect and drop side-table state."""
def detach_node(renderer: Renderer, n: UiNode) {
    entry = get_entry(renderer.layout, n);
    if entry is not None and not entry.rect.is_empty() {
        renderer.damage.append(
            DamageRect(rect=entry.rect.copy(), reason="detach")
        );
    }
    if renderer.cursor_node_id == node_id(n) {
        clear_cursor(renderer);
    }
    clear_node(renderer.layout, n);
}


"""Compute damage rectangles from prev/current layout without painting.

Unit 6 implementation fills this in. Stub raises until then.
"""
def compute_damage(renderer: Renderer, layout_root: UiNode) -> list[DamageRect] {
    _ = (renderer, layout_root);
    raise NotImplementedError("Unit 6: compute_damage");
}


"""Layout, damage, paint, and cursor for one frame.

Returns FrameResult so tests can assert cells and patch scope. Must wrap
terminal writes in synchronized_write. Must not use a full clear to paper
over shrink/move/overlay repair.
"""
def render_frame(
    renderer: Renderer,
    layout_root: UiNode,
    term: Terminal,
) -> FrameResult {
    _ = (renderer, layout_root, term);
    raise NotImplementedError("Unit 6: render_frame");
}


"""Materialize the desired full-frame cell rows without writing a terminal."""
def desired_cells(renderer: Renderer, layout_root: UiNode) -> list[str] {
    _ = (renderer, layout_root);
    raise NotImplementedError("Unit 6: desired_cells");
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
