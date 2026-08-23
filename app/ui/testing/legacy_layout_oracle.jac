"""FROZEN legacy measure/arrange implementation (LAYOUT-ENGINE-PLAN §8.3).

Verbatim snapshot of ui.layout's pre-constraint engine at commit 68eca8d
(2026-08-24), renamed with an oracle_ prefix. Parity tests run this and
the constraint pipeline over the same graph and demand strict equality
after quantization, except the one approved correction: partitions with
three or more fractional grow targets use largest remainder instead of
biasing every leftover cell to the final child.

Migration only — deleted at the M6 cutover. Do not fix bugs here; the
legacy path in ui.layout is the parity reference until then.
"""

import from ui.layout {
    LayoutContract,
    LayoutEntry,
    LayoutKind,
    LayoutTables,
    Rect,
    Size,
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
import from ui.width {
    wrap_text,
}


obj OracleRankedLayer {
    has z_index: int = 0,
        overlay: Overlay | None = None;
}


def _oracle_ranked_layer_key(pair: OracleRankedLayer) -> int {
    return pair.z_index;
}


def _oracle_ensure_entry(tables: LayoutTables, n: UiNode) -> LayoutEntry {
    nid = node_id(n);
    if nid not in tables.entries {
        tables.entries[nid] = LayoutEntry();
    }
    return tables.entries[nid];
}


def _oracle_wrap_content(tables: LayoutTables, n: UiNode, width: int) -> list[str] {
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


def _oracle_flow_children(tables: LayoutTables, parent: UiContainer) -> list[UiNode] {
    out: list[UiNode] = [];
    for child in ordered_children(parent) {
        entry = _oracle_entry_of(tables, child);
        if entry is None {
            continue;
        }
        if entry.contract.kind == LayoutKind.OVERLAY {
            continue;
        }
        out.append(child);
    }
    return out;
}


"""Entry lookup that tolerates unregistered nodes (returns None)."""
def _oracle_entry_of(tables: LayoutTables, n: UiNode) -> LayoutEntry | None {
    return tables.entries.get(node_id(n));
}


def _oracle_clip_intersect(parent_clip: Rect, rect: Rect) -> Rect {
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


def _oracle_leaf_size(tables: LayoutTables, n: UiNode, avail_width: int) -> Size {
    entry = _oracle_ensure_entry(tables, n);
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
    lines = _oracle_wrap_content(tables, n, width if width > 0 else 1);
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
        entry.wrapped_lines = _oracle_wrap_content(tables, n, max(1, width));
    } elif c.kind == LayoutKind.VIEWPORT or c.kind == LayoutKind.GROW {
        # Content height is the intrinsic minimum; arrange assigns final size.
        _ = height;
    }
    entry.measured = Size(width=width, height=height);
    return entry.measured;
}


def _oracle_contract_of(tables: LayoutTables, n: UiNode) -> LayoutContract {
    entry = _oracle_ensure_entry(tables, n);
    return entry.contract;
}


def _oracle_measure_node(tables: LayoutTables, n: UiNode, avail_width: int) -> Size {
    entry = _oracle_ensure_entry(tables, n);
    if not isinstance(n, UiContainer) {
        return _oracle_leaf_size(tables, n, avail_width);
    }
    children = _oracle_flow_children(tables, n);
    if not children {
        return _oracle_leaf_size(tables, n, avail_width);
    }
    c = entry.contract;
    if c.axis == "horizontal" {
        total_w = 0;
        max_h = 0;
        for child in children {
            child_c = _oracle_contract_of(tables, child);
            child_avail = avail_width;
            if (
                child_c.kind == LayoutKind.FIXED
                and child_c.fixed_width is not None
            ) {
                child_avail = int(child_c.fixed_width);
            }
            sz = _oracle_measure_node(tables, child, child_avail);
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
        entry.wrapped_lines = _oracle_wrap_content(tables, n, max(1, width));
        return entry.measured;
    }
    # Vertical composition.
    max_w = avail_width;
    total_h = 0;
    for child in children {
        sz = _oracle_measure_node(tables, child, avail_width);
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
    entry.wrapped_lines = _oracle_wrap_content(tables, n, max(1, width));
    return entry.measured;
}


def _oracle_assign_axis_sizes(
    tables: LayoutTables,
    children: list[UiNode],
    total: int,
    horizontal: bool,
) -> list[int] {
    n_count = len(children);
    sizes: list[int] = [0] * n_count;
    if n_count == 0 {
        return sizes;
    }
    fixed_sum = 0;
    grow_weight_total = 0.0;
    grow_idxs: list[int] = [];
    for (i, child) in enumerate(children) {
        entry = _oracle_ensure_entry(tables, child);
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
            w = c.grow_weight if c.grow_weight > 0.0 else 1.0;
            grow_weight_total += w;
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
            weight = _oracle_ensure_entry(
                tables, children[idx]
            ).contract.grow_weight;
            if weight <= 0.0 {
                weight = 1.0;
            }
            if gi == len(grow_idxs) - 1 {
                sizes[idx] = remaining - allocated;
            } else {
                share = int(remaining * (weight / grow_weight_total));
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


def _oracle_arrange_node(tables: LayoutTables, n: UiNode, parent_clip: Rect) {
    entry = _oracle_ensure_entry(tables, n);
    entry.clip = _oracle_clip_intersect(parent_clip, entry.rect);
    entry.layout_dirty = False;
    entry.semantic_dirty = False;
    if entry.contract.kind == LayoutKind.VIEWPORT {
        # Keep full wrapped content; paint applies scroll_offset.
        width = max(1, entry.rect.width);
        entry.wrapped_lines = _oracle_wrap_content(tables, n, width);
    } elif not entry.wrapped_lines and node_id(n) in tables.content {
        entry.wrapped_lines = _oracle_wrap_content(
            tables, n, max(1, entry.rect.width)
        );
    }
    if not isinstance(n, UiContainer) {
        return;
    }
    children = _oracle_flow_children(tables, n);
    if not children {
        return;
    }
    rect = entry.rect;
    if entry.contract.axis == "horizontal" {
        widths = _oracle_assign_axis_sizes(tables, children, rect.width, True);
        x = rect.x;
        for (i, child) in enumerate(children) {
            child_entry = _oracle_ensure_entry(tables, child);
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
            _oracle_arrange_node(tables, child, entry.clip);
            x += widths[i];
        }
        return;
    }
    heights = _oracle_assign_axis_sizes(tables, children, rect.height, False);
    y = rect.y;
    for (i, child) in enumerate(children) {
        child_entry = _oracle_ensure_entry(tables, child);
        child_entry.rect = Rect(
            x=rect.x, y=y, width=rect.width, height=heights[i]
        );
        _oracle_arrange_node(tables, child, entry.clip);
        y += heights[i];
    }
}


def _oracle_layer_overlays(screen: Screen) -> list[Overlay] {
    pairs: list[OracleRankedLayer] = [];
    for candidate in [screen ->:Layer:->] {
        if isinstance(candidate, Overlay) {
            z: int = 0;
            for layer_edge in [edge screen ->:Layer:-> candidate] {
                z = layer_edge.z_index;
            }
            pairs.append(OracleRankedLayer(z_index=z, overlay=candidate));
        }
    }
    pairs.sort(key=_oracle_ranked_layer_key);
    out: list[Overlay] = [];
    for p in pairs {
        if p.overlay is not None {
            out.append(p.overlay);
        }
    }
    return out;
}


def _oracle_arrange_overlays(
    tables: LayoutTables,
    screen: Screen,
    columns: int,
    rows: int,
) {
    for overlay in _oracle_layer_overlays(screen) {
        entry = _oracle_ensure_entry(tables, overlay);
        _oracle_measure_node(tables, overlay, columns);
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
        entry.wrapped_lines = _oracle_wrap_content(tables, overlay, max(1, w));
        entry.layout_dirty = False;
        entry.semantic_dirty = False;
        if isinstance(overlay, UiContainer) {
            _oracle_arrange_node(tables, overlay, entry.clip);
        }
    }
}


"""Frozen public entry: mirrors ui.layout.measure_and_arrange exactly."""
def legacy_measure_and_arrange(
    tables: LayoutTables,
    layout_root: UiNode,
    columns: int,
    rows: int,
) -> None {
    tables.columns = columns;
    tables.rows = rows;
    _oracle_measure_node(tables, layout_root, columns);
    root_entry = _oracle_ensure_entry(tables, layout_root);
    root_entry.rect = Rect(x=0, y=0, width=columns, height=rows);
    root_clip = root_entry.rect.copy();
    root_entry.clip = root_clip;
    _oracle_arrange_node(tables, layout_root, root_clip);
    if isinstance(layout_root, Screen) {
        _oracle_arrange_overlays(tables, layout_root, columns, rows);
    }
}
