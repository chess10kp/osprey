"""Retained layout side tables for the OSP UI graph.

Geometry, contracts, and measurement live here keyed by jid(node). Semantic
nodes never store rectangles, dirty flags, or wrapped cells.

Measure is bottom-up; arrange is top-down over ordered Child edges. Walker
entry/exit is not used for layout (OSPUI.md §15.3).
"""

import from ui.model {
    UiNode,
    UiContainer,
    Overlay,
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
    entry.scroll_offset = max(0, offset);
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


"""Measure bottom-up and arrange top-down for layout_root under terminal bounds.

Unit 6 implementation fills this in. Stub raises until then.
"""
def measure_and_arrange(
    tables: LayoutTables,
    layout_root: UiNode,
    columns: int,
    rows: int,
) -> None {
    _ = (tables, layout_root, columns, rows);
    raise NotImplementedError("Unit 6: measure_and_arrange");
}
