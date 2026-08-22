"""Retained layout side tables for the OSP UI graph.

Geometry, contracts, and measurement live here keyed by jid(node). Semantic
nodes never store rectangles, dirty flags, or wrapped cells.

Measure is bottom-up; arrange is top-down over ordered Child edges. Walker
entry/exit is not used for layout (OSPUI.md §15.3).
"""

import from ui.model {
    UiNode,
    UiContainer,
    Screen,
    Overlay,
    Layer,
    ordered_children,
    node_id,
}

import from ui.width {
    display_width,
    wrap_text,
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


obj Constraints {
    has min_width: int = 0,
        max_width: int = 100000,
        min_height: int = 0,
        max_height: int = 100000;
}


"""Layout contract kinds from OSPUI.md §15.2."""
enum LayoutKind {
    FIXED = "fixed",
    INTRINSIC = "intrinsic",
    BOUNDED = "bounded",
    GROW = "grow",
    VIEWPORT = "viewport",
    OVERLAY = "overlay"
}


obj LayoutContract {
    has kind: LayoutKind = LayoutKind.INTRINSIC,
        fixed_width: int | None = None,
        fixed_height: int | None = None,
        min_width: int = 0,
        max_width: int = 100000,
        min_height: int = 0,
        max_height: int = 100000,
        grow_weight: float = 1.0,
        overlay_width: int = 0,
        overlay_height: int = 0,
        # Parent composition axis. "horizontal" is the Jackal fragment path.
        axis: str = "vertical";
}


obj LayoutEntry {
    has contract: LayoutContract = LayoutContract(),
        measured: Size = Size(),
        rect: Rect = Rect(),
        prev_rect: Rect = Rect(),
        clip: Rect = Rect(),
        scroll_offset: int = 0,
        wrapped_lines: list[str] = [],
        semantic_dirty: bool = True,
        layout_dirty: bool = True;
}


"""Process-local layout tables owned by the session/renderer, never by nodes."""
obj LayoutTables {
    has entries: dict[str, LayoutEntry] = {},
        content: dict[str, list[str]] = {},
        columns: int = 80,
        rows: int = 24;
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


def fixed(width: int | None = None, height: int | None = None) -> LayoutContract {
    return LayoutContract(
        kind=LayoutKind.FIXED,
        fixed_width=width,
        fixed_height=height,
    );
}


def intrinsic() -> LayoutContract {
    return LayoutContract(kind=LayoutKind.INTRINSIC);
}


def bounded(
    min_width: int = 0,
    max_width: int = 100000,
    min_height: int = 0,
    max_height: int = 100000,
) -> LayoutContract {
    return LayoutContract(
        kind=LayoutKind.BOUNDED,
        min_width=min_width,
        max_width=max_width,
        min_height=min_height,
        max_height=max_height,
    );
}


def grow(weight: float = 1.0) -> LayoutContract {
    return LayoutContract(kind=LayoutKind.GROW, grow_weight=weight);
}


def viewport() -> LayoutContract {
    return LayoutContract(kind=LayoutKind.VIEWPORT);
}


def overlay_contract(width: int, height: int) -> LayoutContract {
    return LayoutContract(
        kind=LayoutKind.OVERLAY,
        overlay_width=width,
        overlay_height=height,
    );
}


"""Mark a container as laying out direct children on one horizontal row."""
def horizontal() -> LayoutContract {
    return LayoutContract(kind=LayoutKind.INTRINSIC, axis="horizontal");
}


def create_layout_tables(columns: int = 80, rows: int = 24) -> LayoutTables {
    return LayoutTables(columns=columns, rows=rows);
}


def _ensure_entry(tables: LayoutTables, n: UiNode) -> LayoutEntry {
    nid = node_id(n);
    if nid not in tables.entries {
        tables.entries[nid] = LayoutEntry();
    }
    return tables.entries[nid];
}


def set_contract(tables: LayoutTables, n: UiNode, contract: LayoutContract) {
    entry = _ensure_entry(tables, n);
    entry.contract = contract;
    entry.layout_dirty = True;
}


def set_content(tables: LayoutTables, n: UiNode, lines: list[str]) {
    nid = node_id(n);
    tables.content[nid] = list(lines);
    entry = _ensure_entry(tables, n);
    entry.semantic_dirty = True;
}


def get_entry(tables: LayoutTables, n: UiNode) -> LayoutEntry | None {
    return tables.entries.get(node_id(n));
}


def rect_of(tables: LayoutTables, n: UiNode) -> Rect {
    entry = get_entry(tables, n);
    if entry is None {
        return Rect();
    }
    return entry.rect.copy();
}


def measured_of(tables: LayoutTables, n: UiNode) -> Size {
    entry = get_entry(tables, n);
    if entry is None {
        return Size();
    }
    return Size(width=entry.measured.width, height=entry.measured.height);
}


def invalidate_semantic(tables: LayoutTables, n: UiNode) {
    entry = _ensure_entry(tables, n);
    entry.semantic_dirty = True;
}


def invalidate_layout(tables: LayoutTables, n: UiNode) {
    entry = _ensure_entry(tables, n);
    entry.layout_dirty = True;
}


def set_scroll_offset(tables: LayoutTables, n: UiNode, offset: int) {
    entry = _ensure_entry(tables, n);
    max_off = max(0, len(entry.wrapped_lines) - max(1, entry.rect.height));
    if entry.rect.height <= 0 and entry.wrapped_lines {
        max_off = max(0, len(entry.wrapped_lines) - 1);
    }
    entry.scroll_offset = max(0, min(offset, max_off));
    entry.layout_dirty = True;
}


"""Remove layout state for a disposed node. Caller must snapshot prev_rect first."""
def clear_node(tables: LayoutTables, n: UiNode) {
    nid = node_id(n);
    if nid in tables.entries {
        del tables.entries[nid];
    }
    if nid in tables.content {
        del tables.content[nid];
    }
}


"""Snapshot current rects into prev_rect before the next measure/arrange."""
def snapshot_rects(tables: LayoutTables) {
    for (_nid, entry) in tables.entries.items() {
        entry.prev_rect = entry.rect.copy();
    }
}


def _flow_children(tables: LayoutTables, parent: UiContainer) -> list[UiNode] {
    out: list[UiNode] = [];
    for child in ordered_children(parent) {
        entry = _ensure_entry(tables, child);
        if entry.contract.kind == LayoutKind.OVERLAY {
            continue;
        }
        out.append(child);
    }
    return out;
}


def _wrap_content(tables: LayoutTables, n: UiNode, width: int) -> list[str] {
    raw = tables.content.get(node_id(n), []);
    if not raw {
        return [];
    }
    wrapped: list[str] = [];
    for line in raw {
        wrapped.extend(wrap_text(line, max(1, width)));
    }
    return wrapped;
}


def _leaf_size(tables: LayoutTables, n: UiNode, avail_width: int) -> Size {
    entry = _ensure_entry(tables, n);
    c = entry.contract;
    width = avail_width;
    if c.kind == LayoutKind.FIXED and c.fixed_width is not None {
        width = int(c.fixed_width);
    } elif c.kind == LayoutKind.OVERLAY {
        width = c.overlay_width;
    } elif c.kind == LayoutKind.BOUNDED {
        width = max(c.min_width, min(avail_width, c.max_width));
    }
    if width < 0 {
        width = 0;
    }
    lines = _wrap_content(tables, n, width if width > 0 else 1);
    entry.wrapped_lines = lines;
    height = len(lines);
    if c.kind == LayoutKind.FIXED {
        if c.fixed_width is not None {
            width = int(c.fixed_width);
        }
        if c.fixed_height is not None {
            height = int(c.fixed_height);
        }
    } elif c.kind == LayoutKind.BOUNDED {
        height = max(c.min_height, min(height, c.max_height));
        width = max(c.min_width, min(width, c.max_width));
    } elif c.kind == LayoutKind.OVERLAY {
        width = c.overlay_width;
        height = c.overlay_height;
        entry.wrapped_lines = _wrap_content(tables, n, max(1, width));
    } elif c.kind == LayoutKind.VIEWPORT or c.kind == LayoutKind.GROW {
        # Content height is the intrinsic minimum; arrange assigns final size.
        _ = height;
    }
    entry.measured = Size(width=width, height=height);
    return entry.measured;
}


def _measure_node(tables: LayoutTables, n: UiNode, avail_width: int) -> Size {
    entry = _ensure_entry(tables, n);
    if not isinstance(n, UiContainer) {
        return _leaf_size(tables, n, avail_width);
    }
    children = _flow_children(tables, n);
    if not children {
        return _leaf_size(tables, n, avail_width);
    }
    c = entry.contract;
    if c.axis == "horizontal" {
        total_w = 0;
        max_h = 0;
        for child in children {
            child_entry = _ensure_entry(tables, child);
            child_c = child_entry.contract;
            child_avail = avail_width;
            if child_c.kind == LayoutKind.FIXED and child_c.fixed_width is not None {
                child_avail = int(child_c.fixed_width);
            }
            sz = _measure_node(tables, child, child_avail);
            total_w += sz.width;
            if sz.height > max_h {
                max_h = sz.height;
            }
        }
        width = avail_width;
        height = max_h;
        if c.kind == LayoutKind.FIXED {
            if c.fixed_width is not None {
                width = int(c.fixed_width);
            }
            if c.fixed_height is not None {
                height = int(c.fixed_height);
            }
        }
        entry.measured = Size(width=width, height=height);
        entry.wrapped_lines = _wrap_content(tables, n, max(1, width));
        return entry.measured;
    }
    # Vertical composition.
    max_w = avail_width;
    total_h = 0;
    for child in children {
        sz = _measure_node(tables, child, avail_width);
        total_h += sz.height;
        if sz.width > max_w {
            max_w = sz.width;
        }
    }
    width = avail_width;
    height = total_h;
    if c.kind == LayoutKind.FIXED {
        if c.fixed_width is not None {
            width = int(c.fixed_width);
        }
        if c.fixed_height is not None {
            height = int(c.fixed_height);
        }
    } elif c.kind == LayoutKind.BOUNDED {
        height = max(c.min_height, min(height, c.max_height));
        width = max(c.min_width, min(width, c.max_width));
    }
    entry.measured = Size(width=width, height=height);
    entry.wrapped_lines = _wrap_content(tables, n, max(1, width));
    return entry.measured;
}


def _clip_intersect(parent_clip: Rect, rect: Rect) -> Rect {
    if parent_clip.is_empty() or rect.is_empty() {
        return Rect();
    }
    x0 = max(parent_clip.x, rect.x);
    y0 = max(parent_clip.y, rect.y);
    x1 = min(parent_clip.right(), rect.right());
    y1 = min(parent_clip.bottom(), rect.bottom());
    if x1 <= x0 or y1 <= y0 {
        return Rect();
    }
    return Rect(x=x0, y=y0, width=x1 - x0, height=y1 - y0);
}


def _assign_axis_sizes(
    tables: LayoutTables,
    children: list[UiNode],
    total: int,
    horizontal: bool,
) -> list[int] {
    n = len(children);
    sizes: list[int] = [0] * n;
    if n == 0 {
        return sizes;
    }
    fixed_sum = 0;
    grow_weight = 0.0;
    grow_idxs: list[int] = [];
    for (i, child) in enumerate(children) {
        entry = _ensure_entry(tables, child);
        c = entry.contract;
        if c.kind == LayoutKind.FIXED {
            if horizontal {
                sizes[i] = (
                    int(c.fixed_width)
                    if c.fixed_width is not None
                    else entry.measured.width
                );
            } else {
                sizes[i] = (
                    int(c.fixed_height)
                    if c.fixed_height is not None
                    else entry.measured.height
                );
            }
            fixed_sum += sizes[i];
        } elif c.kind == LayoutKind.GROW or c.kind == LayoutKind.VIEWPORT {
            grow_idxs.append(i);
            grow_weight += c.grow_weight if c.grow_weight > 0.0 else 1.0;
            sizes[i] = 0;
        } else {
            # intrinsic / bounded use measured size on this axis
            if horizontal {
                sizes[i] = entry.measured.width;
            } else {
                sizes[i] = entry.measured.height;
            }
            fixed_sum += sizes[i];
        }
    }
    remaining = total - fixed_sum;
    if remaining < 0 {
        remaining = 0;
    }
    if grow_idxs {
        allocated = 0;
        for (gi, idx) in enumerate(grow_idxs) {
            entry = _ensure_entry(tables, children[idx]);
            weight = entry.contract.grow_weight;
            if weight <= 0.0 {
                weight = 1.0;
            }
            if gi == len(grow_idxs) - 1 {
                sizes[idx] = remaining - allocated;
            } else {
                share = int(remaining * (weight / grow_weight));
                sizes[idx] = share;
                allocated += share;
            }
            if sizes[idx] < 0 {
                sizes[idx] = 0;
            }
        }
    }
    return sizes;
}


def _arrange_node(tables: LayoutTables, n: UiNode, parent_clip: Rect) {
    entry = _ensure_entry(tables, n);
    entry.clip = _clip_intersect(parent_clip, entry.rect);
    entry.layout_dirty = False;
    entry.semantic_dirty = False;
    if entry.contract.kind == LayoutKind.VIEWPORT {
        # Keep full wrapped content; paint applies scroll_offset.
        width = max(1, entry.rect.width);
        entry.wrapped_lines = _wrap_content(tables, n, width);
    } elif not entry.wrapped_lines and node_id(n) in tables.content {
        entry.wrapped_lines = _wrap_content(
            tables, n, max(1, entry.rect.width)
        );
    }
    if not isinstance(n, UiContainer) {
        return;
    }
    children = _flow_children(tables, n);
    if not children {
        return;
    }
    rect = entry.rect;
    if entry.contract.axis == "horizontal" {
        widths = _assign_axis_sizes(tables, children, rect.width, True);
        x = rect.x;
        for (i, child) in enumerate(children) {
            child_entry = _ensure_entry(tables, child);
            h = child_entry.measured.height;
            if child_entry.contract.kind == LayoutKind.FIXED {
                if child_entry.contract.fixed_height is not None {
                    h = int(child_entry.contract.fixed_height);
                }
            } elif (
                child_entry.contract.kind == LayoutKind.GROW
                or child_entry.contract.kind == LayoutKind.VIEWPORT
            ) {
                h = rect.height;
            }
            child_entry.rect = Rect(x=x, y=rect.y, width=widths[i], height=h);
            _arrange_node(tables, child, entry.clip);
            x += widths[i];
        }
        return;
    }
    heights = _assign_axis_sizes(tables, children, rect.height, False);
    y = rect.y;
    for (i, child) in enumerate(children) {
        child_entry = _ensure_entry(tables, child);
        child_entry.rect = Rect(
            x=rect.x, y=y, width=rect.width, height=heights[i]
        );
        _arrange_node(tables, child, entry.clip);
        y += heights[i];
    }
}


obj RankedLayer {
    has z_index: int = 0,
        overlay: Overlay | None = None;
}


def _ranked_layer_key(pair: RankedLayer) -> int {
    return pair.z_index;
}


def _layer_overlays(screen: Screen) -> list[Overlay] {
    pairs: list[RankedLayer] = [];
    for candidate in [screen ->:Layer:->] {
        if isinstance(candidate, Overlay) {
            z = 0;
            for layer_edge in [edge screen ->:Layer:-> candidate] {
                z = layer_edge.z_index;
            }
            pairs.append(RankedLayer(z_index=z, overlay=candidate));
        }
    }
    pairs.sort(key=_ranked_layer_key);
    out: list[Overlay] = [];
    for p in pairs {
        if p.overlay is not None {
            out.append(p.overlay);
        }
    }
    return out;
}


def _arrange_overlays(tables: LayoutTables, screen: Screen, columns: int, rows: int) {
    for overlay in _layer_overlays(screen) {
        entry = _ensure_entry(tables, overlay);
        _measure_node(tables, overlay, columns);
        w = entry.contract.overlay_width;
        h = entry.contract.overlay_height;
        if entry.contract.kind != LayoutKind.OVERLAY {
            w = entry.measured.width;
            h = entry.measured.height;
        }
        if w <= 0 {
            w = entry.measured.width;
        }
        if h <= 0 {
            h = entry.measured.height;
        }
        x = max(0, (columns - w) // 2);
        y = max(0, (rows - h) // 2);
        if x + w > columns {
            x = max(0, columns - w);
        }
        if y + h > rows {
            y = max(0, rows - h);
        }
        entry.rect = Rect(x=x, y=y, width=w, height=h);
        entry.clip = entry.rect.copy();
        entry.wrapped_lines = _wrap_content(tables, overlay, max(1, w));
        entry.layout_dirty = False;
        entry.semantic_dirty = False;
        if isinstance(overlay, UiContainer) {
            _arrange_node(tables, overlay, entry.clip);
        }
    }
}


"""Public helpers used by the renderer paint pass."""
def flow_children(tables: LayoutTables, parent: UiContainer) -> list[UiNode] {
    return _flow_children(tables, parent);
}


def layer_overlays(screen: Screen) -> list[Overlay] {
    return _layer_overlays(screen);
}


"""Measure bottom-up and arrange top-down for layout_root under terminal bounds."""
def measure_and_arrange(
    tables: LayoutTables,
    layout_root: UiNode,
    columns: int,
    rows: int,
) -> None {
    tables.columns = columns;
    tables.rows = rows;
    _measure_node(tables, layout_root, columns);
    root_entry = _ensure_entry(tables, layout_root);
    root_entry.rect = Rect(x=0, y=0, width=columns, height=rows);
    root_clip = root_entry.rect.copy();
    root_entry.clip = root_clip;
    _arrange_node(tables, layout_root, root_clip);
    if isinstance(layout_root, Screen) {
        _arrange_overlays(tables, layout_root, columns, rows);
    }
}
