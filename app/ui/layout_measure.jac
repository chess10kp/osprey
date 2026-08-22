"""Width-dependent text measurement with a bounded cache (plan §7.1).

Axis separation puts this NON-linear operation outside the solver:
natural (unwrapped) width feeds the horizontal phase; wrapped line
counts at QUANTIZED integer widths feed the vertical phase. Text is
wrapped exactly once per (node, content revision, integer width, style
revision) — the cache holds one entry per node because revisions are
monotonic and older wraps can never be reused again (plan §4 invariant
6); memory is therefore O(nodes), never O(history).

Known cost by design: viewport resize ping-pong (A->B->A widths)
invalidates the single entry per width change and recomputes wraps every
frame. That is correct behavior under this bound, not a bug to fix with
a multi-entry cache; revisit only if resize benchmarks say otherwise.
"""

import from ui.width {
    display_width,
    wrap_text,
}
import from ui.layout_state {
    LayoutState,
    MeasureEntry,
}


"""Natural (unwrapped) display width of registered content lines.

Empty or missing content measures 0 — callers decide their own fallback
for INTRINSIC nodes without content."""
def natural_width(lines: list[str]) -> int {
    best = 0;
    for line in lines {
        w = display_width(line);
        if w > best {
            best = w;
        }
    }
    return best;
}


def _cache_valid(
    cached: MeasureEntry,
    width: int,
    content_revision: int,
    style_revision: int,
) -> bool {
    return (
        cached.width == width
        and cached.content_revision == content_revision
        and cached.style_revision == style_revision
    );
}


"""Wrap content to exactly `width` columns, cached per node.

Returns the wrapped lines for the CURRENT content at this width,
populating or reusing state.measurement_cache[node_id]. Width is clamped
to >= 1 so degenerate viewports still wrap deterministically."""
def wrapped_lines_at(
    state: LayoutState,
    id_str: str,
    width: int,
) -> list[str] {
    if width < 1 {
        width = 1;
    }
    content = state.content.get(id_str);
    lines: list[str] = [];
    cr = 0;
    sr = 0;
    if content is not None {
        lines = content.lines;
        cr = content.content_revision;
        sr = content.style_revision;
    }

    cached = state.measurement_cache.get(id_str);
    if cached is not None and _cache_valid(cached, width, cr, sr) {
        return cached.lines;
    }

    wrapped: list[str] = [];
    for line in lines {
        wrapped.extend(wrap_text(line, width));
    }
    state.measurement_cache[id_str] = MeasureEntry(
        width=width,
        content_revision=cr,
        style_revision=sr,
        lines=wrapped,
    );
    return wrapped;
}


"""Wrapped height in rows for one node at one integer width."""
def wrapped_height(
    state: LayoutState,
    id_str: str,
    width: int,
) -> int {
    if width < 1 {
        width = 1;
    }
    return len(wrapped_lines_at(state, id_str, width));
}
