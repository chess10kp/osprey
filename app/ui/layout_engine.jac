"""Layout orchestration: the axis-separated compute pipeline (plan §7.1).

LIVES OUTSIDE ui.layout for the same reason ui.layout_state does: four
permanent names collide with legacy helpers until the M6 cutover. At
cutover compute_layout moves into ui.layout and this module folds back.

Pipeline (no convergence loop):

1. natural-width measurement from registered content
2. horizontal-only compile + solve (phase "h")
3. horizontal quantization: root exact; flow partitions via the §7.2
   largest-remainder quantizer using PartitionInfo recorded by the
   compiler; every other node snaps its solved left/right edges
4. wrapped-height measurement ONCE at each node's integer width
5. vertical-only compile + solve (phase "v"), measured heights as
   natural-size constants
6. vertical quantization (mirror of step 3) + clip propagation +
   scroll clamping + overlay arrangement
7. atomic publish: state.last_frame replaced only after every phase
   succeeds; a failed run leaves the prior frame untouched

Hard-overflow partitions (FIXED claims > span) bypass the quantizer per
its documented contract: children keep snapped solved edges and the
OVERFLOW warning travels on the published frame. Overlay origins clamp
to (0, 0) keeping their requested size, clipped to the viewport
(plan §6.3).
"""

import from ui.layout {
    FrameEntry,
    LayoutDiagnostic,
    LayoutError,
    LayoutFrame,
    LayoutResult,
    LayoutSeverity,
    Rect,
    Size,
    Viewport,
}
import from ui.layout_compile {
    CompileResult,
    NodeEdges,
    PartitionInfo,
    _ScopedNode,
    collect_scope_for_engine,
    compile_layout,
}
import from ui.layout_measure {
    natural_width,
    wrapped_lines_at,
}
import from ui.layout_quantize {
    PartitionRequest,
    quantize_partition,
    snap_edge,
}
import from ui.layout_state {
    LayoutState,
}
import from ui.model {
    UiNode,
    node_id,
}


def _fail(diagnostics: list[LayoutDiagnostic]) -> LayoutResult {
    return LayoutResult(ok=False, frame=None, diagnostics=diagnostics);
}


def _overflow_warning(node_ids: list[str]) -> LayoutDiagnostic {
    return LayoutDiagnostic(
        code=LayoutError.OVERFLOW,
        severity=LayoutSeverity.WARNING,
        message="partition exceeded span; quantized clip-aware",
        node_ids=node_ids,
    );
}


"""Non-overlay ordered child ids of one scoped parent.

scope.order is BFS: each parent's children appear contiguously in rank
order, so a single scan groups them correctly."""
def _child_ids(scope_order: list[_ScopedNode], parent_id: str) -> list[str] {
    out: list[str] = [];
    for scoped in scope_order {
        if scoped.parent_id == parent_id and not scoped.is_overlay {
            out.append(scoped.id_str);
        }
    }
    return out;
}


def _copy_rect(r: Rect) -> Rect {
    return Rect(x=r.x, y=r.y, width=r.width, height=r.height);
}


"""Place one axis of the tree top-down.

Partition members are positioned by largest-remainder sizes cumulative
from the parent's start cell (exact closure); every other child snaps
its solved edges — pinned children hold byte-identical solved floats to
their parent, so snapping preserves pinning exactly."""
def _place_axis(
    result: CompileResult,
    values: dict[int, float],
    order: list,
    parent_id: str,
    p_start: int,
    p_end: int,
    infos: dict[str, PartitionInfo],
    starts: dict[str, int],
    ends: dict[str, int],
    warnings: list[LayoutDiagnostic],
    horizontal: bool,
) -> None {
    kids = _child_ids(order, parent_id);
    if len(kids) == 0 {
        return;
    }

    placed = False;
    info = infos.get(parent_id);
    aligned = False;
    if info is not None and len(info.child_ids) == len(kids) {
        # Element-wise identity, not just length: quantized sizes must
        # never map onto the wrong children if grouping ever drifts.
        aligned = True;
        for i in range(len(kids)) {
            if info.child_ids[i] != kids[i] {
                aligned = False;
            }
        }
        if not aligned {
            warnings.append(LayoutDiagnostic(
                code=LayoutError.INTERNAL_INVARIANT,
                severity=LayoutSeverity.ERROR,
                message="partition child order misaligned with scope walk",
                node_ids=[parent_id],
            ));
        }
    }
    if info is not None and aligned {
        req = PartitionRequest(
            span=p_end - p_start,
            targets=info.targets,
            fixed=info.fixed,
            minimums=info.minimums,
            maximums=info.maximums,
        );
        qr = quantize_partition(req);
        if qr.ok {
            pos = p_start;
            for i in range(len(kids)) {
                kid = kids[i];
                starts[kid] = pos;
                ends[kid] = pos + qr.sizes[i];
                pos += qr.sizes[i];
            }
            placed = True;
        } else {
            # Hard overflow: no honest integer closure exists; snap the
            # solved edges clip-aware and warn (quantizer contract).
            warnings.append(_overflow_warning([parent_id]));
        }
    }

    if not placed {
        for kid in kids {
            e = result.nodes[kid];
            if horizontal {
                starts[kid] = snap_edge(values[e.left.id]);
                ends[kid] = snap_edge(values[e.right.id]);
            } else {
                starts[kid] = snap_edge(values[e.top.id]);
                ends[kid] = snap_edge(values[e.bottom.id]);
            }
        }
    }

    for kid in kids {
        _place_axis(
            result, values, order, kid,
            starts[kid], ends[kid], infos,
            starts, ends, warnings, horizontal,
        );
    }
}


"""Full pipeline: registry + topology -> published LayoutFrame."""
def compute_layout(
    state: LayoutState,
    layout_root: UiNode,
    viewport: Viewport,
) -> LayoutResult {
    scope = collect_scope_for_engine(layout_root);
    if scope.error is not None {
        return _fail([scope.error]);
    }
    order = scope.order;
    root_id = node_id(layout_root);

    # ---- Phase H ----------------------------------------------------
    naturals_w: dict[str, Size] = {};
    for scoped in order {
        id_str = scoped.id_str;
        lines: list[str] = [];
        content = state.content.get(id_str);
        if content is not None {
            lines = content.lines;
        }
        naturals_w[id_str] = Size(width=natural_width(lines), height=0);
    }

    ch = compile_layout(state, layout_root, viewport, naturals_w, "h");
    if not ch.ok or ch.solver is None {
        return _fail(ch.diagnostics);
    }
    hv = ch.solver.snapshot().values;

    L: dict[str, int] = {};
    R: dict[str, int] = {};
    L[root_id] = 0;
    R[root_id] = viewport.columns;
    hinfos: dict[str, PartitionInfo] = {};
    for info in ch.partitions {
        if info.horizontal {
            hinfos[info.parent_id] = info;
        }
    }
    warnings: list[LayoutDiagnostic] = [];
    _place_axis(
        ch, hv, order, root_id, 0, viewport.columns,
        hinfos, L, R, warnings, True,
    );
    # Overlays sit outside every flow partition: snap each axis's cells
    # in its own phase before that axis is consumed.
    for scoped in order {
        if not scoped.is_overlay {
            continue;
        }
        id_str = scoped.id_str;
        eh = ch.nodes[id_str];
        L[id_str] = snap_edge(hv[eh.left.id]);
        R[id_str] = snap_edge(hv[eh.right.id]);
    }

    # ---- Measure once at integer widths ------------------------------
    widths: dict[str, int] = {};
    wrapped_by_node: dict[str, list[str]] = {};
    for scoped in order {
        id_str = scoped.id_str;
        w = R[id_str] - L[id_str];
        if w < 0 {
            return _fail([LayoutDiagnostic(
                code=LayoutError.INTERNAL_INVARIANT,
                severity=LayoutSeverity.ERROR,
                message="negative derived width",
                node_ids=[id_str],
            )]);
        }
        widths[id_str] = w;
        wrapped_by_node[id_str] = list(wrapped_lines_at(state, id_str, w));
    }

    # ---- Phase V -----------------------------------------------------
    naturals_h: dict[str, Size] = {};
    for scoped in order {
        id_str = scoped.id_str;
        naturals_h[id_str] = Size(
            width=widths[id_str],
            height=len(wrapped_by_node[id_str]),
        );
    }

    cv = compile_layout(state, layout_root, viewport, naturals_h, "v");
    if not cv.ok or cv.solver is None {
        return _fail(cv.diagnostics);
    }
    vv = cv.solver.snapshot().values;

    T: dict[str, int] = {};
    B: dict[str, int] = {};
    T[root_id] = 0;
    B[root_id] = viewport.rows;
    vinfos: dict[str, PartitionInfo] = {};
    for info in cv.partitions {
        if not info.horizontal {
            vinfos[info.parent_id] = info;
        }
    }
    _place_axis(
        cv, vv, order, root_id, 0, viewport.rows,
        vinfos, T, B, warnings, False,
    );
    for scoped in order {
        if not scoped.is_overlay {
            continue;
        }
        id_str = scoped.id_str;
        ev = cv.nodes[id_str];
        T[id_str] = snap_edge(vv[ev.top.id]);
        B[id_str] = snap_edge(vv[ev.bottom.id]);
    }


    # ---- Frame construction ------------------------------------------
    entries: dict[str, FrameEntry] = {};
    clips: dict[str, Rect] = {};

    for scoped in order {
        id_str = scoped.id_str;
        l = L[id_str];
        r = R[id_str];
        t = T[id_str];
        b = B[id_str];

        w = r - l;
        h = b - t;
        if scoped.is_overlay {
            # Origin clamped into the viewport; SIZE KEPT AS SOLVED so a
            # too-big fixed overlay clips instead of shrinking (§6.3).
            if l < 0 {
                l = 0;
            }
            if t < 0 {
                t = 0;
            }
        }
        if w < 0 or h < 0 {
            return _fail([LayoutDiagnostic(
                code=LayoutError.INTERNAL_INVARIANT,
                severity=LayoutSeverity.ERROR,
                message="negative derived size",
                node_ids=[id_str],
            )]);
        }
        rect = Rect(x=l, y=t, width=w, height=h);

        # Clip propagation: BFS order guarantees the parent clip exists.
        if scoped.parent_id == "" {
            if scoped.is_overlay {
                # No Child parent: overlays clip against the viewport.
                vw = viewport.columns - l;
                vh = viewport.rows - t;
                cw = w if w < vw else vw;
                chh = h if h < vh else vh;
                if cw < 0 {
                    cw = 0;
                }
                if chh < 0 {
                    chh = 0;
                }
                clip = Rect(x=l, y=t, width=cw, height=chh);
            } else {
                clip = _copy_rect(rect);
            }
        } else {
            pclip = clips[scoped.parent_id];
            if pclip.width <= 0 or pclip.height <= 0 or w <= 0 or h <= 0 {
                clip = Rect(x=0, y=0, width=0, height=0);
            } else {
                x0 = pclip.x if pclip.x > l else l;
                y0 = pclip.y if pclip.y > t else t;
                pr_end = pclip.x + pclip.width;
                pb_end = pclip.y + pclip.height;
                x1 = pr_end if pr_end < r else r;
                y1 = pb_end if pb_end < b else b;
                cw = x1 - x0;
                chh = y1 - y0;
                if cw < 0 {
                    cw = 0;
                }
                if chh < 0 {
                    chh = 0;
                }
                clip = Rect(x=x0, y=y0, width=cw, height=chh);
            }
        }
        clips[id_str] = clip;

        wrapped = wrapped_by_node[id_str];
        requested = 0;
        spec = state.specs.get(id_str);
        if spec is not None and spec.scroll_vertical {
            requested = state.scroll_requests.get(id_str, 0);
        }
        max_off = max(0, len(wrapped) - max(1, h));
        off = min(max(requested, 0), max_off);

        entries[id_str] = FrameEntry(
            measured=Size(width=w, height=h),
            rect=_copy_rect(rect),
            clip=clip,
            wrapped_lines=list(wrapped),
            requested_scroll_offset=requested,
            scroll_offset=off,
            max_scroll_offset=max_off,
        );
    }

    overlay_ids: list[str] = [];
    for scoped in order {
        if scoped.is_overlay {
            overlay_ids.append(scoped.id_str);
        }
    }

    prev_gen = 0;
    if state.last_frame is not None {
        prev_gen = state.last_frame.generation;
    }
    frame = LayoutFrame(
        generation=prev_gen + 1,
        viewport=Viewport(columns=viewport.columns, rows=viewport.rows),
        entries=entries,
        overlay_ids=overlay_ids,
    );
    state.last_frame = frame;

    diags: list[LayoutDiagnostic] = [];
    for d in warnings {
        diags.append(d);
    }
    return LayoutResult(ok=True, frame=frame, diagnostics=diags);
}
