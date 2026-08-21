"""Structural region painter for OSP-owned terminal updates.

Instead of flattening the whole frame and diffing strings, compose_layout()
assigns each node a screen_row and line_count. paint_frame() walks only nodes
whose region moved or changed and emits direct CSI patches.
"""

import from ui.model {
    UiNode,
    compose_layout,
    collect_paint_jobs,
    mark_painted,
}


def _csi_n(n: int) -> int {
    return int(n);
}


def _move_to_row(state: dict, write: any, row: int) {
    diff = row - state["cursor_row"];
    if diff > 0 {
        write(f"\x1b[{_csi_n(diff)}B");
    } elif diff < 0 {
        write(f"\x1b[{_csi_n(-diff)}A");
    }
    state["cursor_row"] = row;
}


def _write_line(state: dict, write: any, row: int, text: str) {
    _move_to_row(state, write, row);
    write("\r\x1b[2K");
    write(text);
}


def _paint_node(state: dict, write: any, n: UiNode) {
    start = n.screen_row;
    for (offset, line) in enumerate(n.cached_lines) {
        _write_line(state, write, start + offset, line);
    }
}


"""Compose layout, paint dirty regions, return nodes written this frame."""
def paint_frame(root_view: UiNode, width: int, write: any) -> list[UiNode] {
    compose_layout(root_view, width);
    jobs = collect_paint_jobs(root_view, width);
    if not jobs {
        return [];
    }
    state = {"cursor_row": 0};
    for n in jobs {
        _paint_node(state, write, n);
        mark_painted(n, width);
    }
    return jobs;
}
