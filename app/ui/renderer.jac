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
    ordered_children,
    node_id,
}

import from ui.layout {
    LayoutTables,
    LayoutContract,
    LayoutEntry,
    LayoutKind,
    Rect,
    create_layout_tables,
    set_contract,
    set_content,
    get_entry,
    invalidate_semantic,
    invalidate_layout,
    clear_node,
    snapshot_rects,
    measure_and_arrange,
    rect_union,
    layer_overlays,
    flow_children,
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


obj CursorPos {
    has row: int = -1,
        col: int = -1;
}


obj Renderer {
    has layout: LayoutTables,
        # Retained previous frame as styled cells (OSPUI §15.1).
        previous: CellBuffer | None = None,
        damage: list[DamageRect] = [],
        cursor_node_id: str = "",
        cursor_row_offset: int = 0,
        cursor_col_offset: int = 0,
        last_cursor_row: int = -1,
        last_cursor_col: int = -1,
        last_cursor_visible: bool = False,
        graph_revision: int = 0,
        # Node ids marked dirty before measure clears the flags.
        pending_semantic: set[str] = set(),
        pending_layout: set[str] = set();
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
    renderer.pending_semantic.add(node_id(n));
}


def mark_layout_dirty(renderer: Renderer, n: UiNode) {
    invalidate_layout(renderer.layout, n);
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


def _blank_buffer(columns: int, rows: int) -> CellBuffer {
    return create_buffer(columns, rows);
}


def _set_cell(
    buf: CellBuffer,
    row: int,
    col: int,
    ch: str,
    attrs: StyleAttrs | None = None,
) {
    if row < 0 or row >= buf.rows or col < 0 or col >= buf.columns {
        return;
    }
    style = attrs if attrs is not None else StyleAttrs();
    buf.cells[row][col] = StyledCell(
        ch=ch if ch else " ",
        attrs=StyleAttrs(
            fg=style.fg,
            bg=style.bg,
            bold=style.bold,
            dim=style.dim,
            italic=style.italic,
            underline=style.underline,
            reverse=style.reverse,
        ),
    );
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
    layout_entry: LayoutEntry,
    columns: int,
    rows_n: int,
) {
    _ = (columns, rows_n);
    rect = layout_entry.rect;
    clip = layout_entry.clip if not layout_entry.clip.is_empty() else rect;
    if clip.is_empty() or rect.is_empty() {
        return;
    }
    lines = layout_entry.wrapped_lines;
    scroll = 0;
    if layout_entry.contract.kind == LayoutKind.VIEWPORT {
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


def _paint_tree(
    tables: LayoutTables,
    n: UiNode,
    buf: CellBuffer,
    columns: int,
    rows_n: int,
) {
    entry = get_entry(tables, n);
    if entry is not None {
        if entry.contract.kind != LayoutKind.OVERLAY {
            if entry.wrapped_lines or node_id(n) in tables.content {
                _paint_entry_lines(buf, entry, columns, rows_n);
            }
        }
    }
    if isinstance(n, UiContainer) {
        for child in flow_children(tables, n) {
            _paint_tree(tables, child, buf, columns, rows_n);
        }
    }
}


def _paint_frame_buffer(renderer: Renderer, layout_root: UiNode) -> CellBuffer {
    cols = renderer.layout.columns;
    rows_n = renderer.layout.rows;
    buf = _blank_buffer(cols, rows_n);
    _paint_tree(renderer.layout, layout_root, buf, cols, rows_n);
    if isinstance(layout_root, Screen) {
        for overlay in layer_overlays(layout_root) {
            entry = get_entry(renderer.layout, overlay);
            if entry is not None {
                _paint_entry_lines(buf, entry, cols, rows_n);
            }
        }
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
    tables = renderer.layout;
    entry = get_entry(tables, n);
    nid = node_id(n);
    if entry is not None {
        prev = entry.prev_rect;
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
            for overlay in layer_overlays(n) {
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
                    width=renderer.layout.columns,
                    height=renderer.layout.rows,
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


def _pad_row(row: str, columns: int) -> str {
    if len(row) >= columns {
        return row[:columns];
    }
    return row + (" " * (columns - len(row)));
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
    entry = renderer.layout.entries.get(renderer.cursor_node_id);
    if entry is None or entry.rect.is_empty() {
        return CursorPos();
    }
    row = entry.rect.y + renderer.cursor_row_offset;
    col = entry.rect.x + renderer.cursor_col_offset;
    if row < 0 or col < 0 {
        return CursorPos();
    }
    if row >= renderer.layout.rows or col >= renderer.layout.columns {
        return CursorPos();
    }
    return CursorPos(row=row, col=col);
}


"""Materialize the desired full-frame cell rows without writing a terminal."""
def desired_cells(renderer: Renderer, layout_root: UiNode) -> list[str] {
    measure_and_arrange(
        renderer.layout,
        layout_root,
        renderer.layout.columns,
        renderer.layout.rows,
    );
    buf = _paint_frame_buffer(renderer, layout_root);
    return buffer_to_plain_rows(buf);
}


"""Materialize the desired styled cell buffer without writing a terminal."""
def desired_buffer(renderer: Renderer, layout_root: UiNode) -> CellBuffer {
    measure_and_arrange(
        renderer.layout,
        layout_root,
        renderer.layout.columns,
        renderer.layout.rows,
    );
    return _paint_frame_buffer(renderer, layout_root);
}


"""Layout, damage, paint, and cursor for one frame."""
def render_frame(
    renderer: Renderer,
    layout_root: UiNode,
    term: Terminal,
) -> FrameResult {
    cols = term.columns if term.columns > 0 else renderer.layout.columns;
    rows_n = term.rows if term.rows > 0 else renderer.layout.rows;
    renderer.layout.columns = cols;
    renderer.layout.rows = rows_n;

    # Capture dirty flags from side-table entries set via set_content/etc.
    for (nid, entry) in renderer.layout.entries.items() {
        if entry.semantic_dirty {
            renderer.pending_semantic.add(nid);
        }
        if entry.layout_dirty {
            renderer.pending_layout.add(nid);
        }
    }

    measure_and_arrange(renderer.layout, layout_root, cols, rows_n);
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
    snapshot_rects(renderer.layout);
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
