"""Dual-run parity corpus: frozen oracle vs constraint pipeline (§8.3).

Every scenario builds ONE graph and configures both engines over it:
the frozen legacy measure/arrange (ui.testing.legacy_layout_oracle on
LayoutTables) and compute_layout (LayoutState + specs). Strict equality
is required on rects, clips, wrapped lines, and clamped scroll offsets —
except the single approved correction: partitions with three or more
fractional grow targets distribute by largest remainder instead of
biasing leftover cells to the final child; those assertions check
closure and sub-cell residual instead.

Contract -> spec mapping used throughout (documented divergence risks):
- fixed(None, h)          -> AxisSize FILL x FIXED(h)
- viewport()              -> FILL x GROW(scroll_vertical=True)
- grow(w) in a column     -> FILL x GROW(w)
- grow(w) in a row        -> GROW(w) x FILL
- intrinsic leaf in a row -> GROW? no: FIXED/FILL only when legacy pins;
  intrinsic-height leaves use cross_align START to keep natural height.
"""

import from ui.layout {
    Align,
    Axis,
    AxisSize,
    LayoutFrame,
    LayoutEntry,
    LayoutSpec,
    LayoutState,
    LayoutTables,
    SizeMode,
    Viewport,
    create_layout_tables,
    fixed,
    get_entry,
    grow,
    horizontal,
    intrinsic,
    overlay_contract,
    set_contract,
    set_content as legacy_set_content,
    set_scroll_offset as legacy_set_scroll_offset,
    viewport,
}
import from ui.layout_engine {
    compute_layout,
}
import from ui.layout_state {
    create_layout_state,
    set_content,
    set_scroll_offset,
    set_spec,
}
import from ui.model {
    ApprovalOverlay,
    Child,
    Header,
    Layer,
    MainScreen,
    Prompt,
    Status,
    TranscriptView,
    UiContainer,
    UiNode,
    node_id,
}
import from ui.testing.legacy_layout_oracle {
    legacy_measure_and_arrange,
}


obj _PNode {
    has tables: LayoutTables,
        state: LayoutState,
        screen_node: MainScreen,
        nodes: dict[str, UiNode];
}


def _fillw() -> AxisSize {
    return AxisSize(mode=SizeMode.FILL);
}


def _fx(n: float) -> AxisSize {
    return AxisSize(mode=SizeMode.FIXED, preferred=n);
}


def _gr(w: float) -> AxisSize {
    return AxisSize(mode=SizeMode.GROW, grow_weight=w);
}



def _entry_of(tables: LayoutTables, n: UiNode) -> LayoutEntry {
    found = get_entry(tables, n);
    if found is None {
        raise ValueError("missing legacy layout entry");
    }
    return found;
}

def _viewports() -> list[Viewport] {
    return [
        Viewport(columns=0, rows=0),
        Viewport(columns=1, rows=1),
        Viewport(columns=2, rows=1),
        Viewport(columns=8, rows=3),
        Viewport(columns=40, rows=12),
        Viewport(columns=80, rows=24),
        Viewport(columns=200, rows=60),
    ];
}


"""Configure both registries for the standard four-region shell."""
def _build_shell(content: dict[str, list[str]]) -> _PNode {
    screen = MainScreen(key="main");
    header = Header(key="header");
    transcript = TranscriptView(key="transcript");
    status = Status(key="status");
    prompt = Prompt(key="prompt");
    screen +>:Child(rank=1024):+> header;
    screen +>:Child(rank=2048):+> transcript;
    screen +>:Child(rank=3072):+> status;
    screen +>:Child(rank=4096):+> prompt;

    tables = create_layout_tables();
    set_contract(tables, screen, intrinsic());
    set_contract(tables, header, fixed(None, 1));
    set_contract(tables, transcript, viewport());
    set_contract(tables, status, fixed(None, 1));
    set_contract(tables, prompt, fixed(None, 2));
    for key in content.keys() {
        if key == "header" {
            legacy_set_content(tables, header, content[key]);
        } elif key == "transcript" {
            legacy_set_content(tables, transcript, content[key]);
        } elif key == "status" {
            legacy_set_content(tables, status, content[key]);
        } elif key == "prompt" {
            legacy_set_content(tables, prompt, content[key]);
        }
    }

    state = create_layout_state(80, 24);
    set_spec(state, screen, LayoutSpec(width=_fillw(), height=_fillw()));
    set_spec(state, header, LayoutSpec(width=_fillw(), height=_fx(1.0)));
    set_spec(
        state,
        transcript,
        LayoutSpec(width=_fillw(), height=_gr(1.0), scroll_vertical=True),
    );
    set_spec(state, status, LayoutSpec(width=_fillw(), height=_fx(1.0)));
    set_spec(state, prompt, LayoutSpec(width=_fillw(), height=_fx(2.0)));
    rev = 1;
    for key in content.keys() {
        if key == "header" {
            set_content(state, header, content[key], rev);
        } elif key == "transcript" {
            set_content(state, transcript, content[key], rev);
        } elif key == "status" {
            set_content(state, status, content[key], rev);
        } elif key == "prompt" {
            set_content(state, prompt, content[key], rev);
        }
        rev += 1;
    }

    nodes: dict[str, UiNode] = {};
    nodes["screen"] = screen;
    nodes["header"] = header;
    nodes["transcript"] = transcript;
    nodes["status"] = status;
    nodes["prompt"] = prompt;
    return _PNode(tables=tables, state=state, screen_node=screen, nodes=nodes);
}


glob SHELL_IDS: list[str] = [
    "screen",
    "header",
    "transcript",
    "status",
    "prompt",
];


def _run_both(p: _PNode, columns: int, rows: int) -> bool {
    legacy_measure_and_arrange(p.tables, p.screen_node, columns, rows);
    r = compute_layout(p.state, p.screen_node, Viewport(columns=columns, rows=rows));
    return r.ok;
}


def _frame_of(state: LayoutState) -> LayoutFrame {
    found = state.last_frame;
    if found is None {
        raise ValueError("missing published frame");
    }
    return found;
}


def _assert_rects_equal(p: _PNode, target_node: UiNode, id_str: str) -> None {
    legacy_entry = _entry_of(p.tables, target_node);
    new_entry = _frame_of(p.state).entries[id_str];
    assert legacy_entry.rect.x == new_entry.rect.x;
    assert legacy_entry.rect.y == new_entry.rect.y;
    assert legacy_entry.rect.width == new_entry.rect.width;
    assert legacy_entry.rect.height == new_entry.rect.height;
}


def _assert_clips_equal(p: _PNode, target_node: UiNode, id_str: str) -> None {
    legacy_entry = _entry_of(p.tables, target_node);
    new_entry = _frame_of(p.state).entries[id_str];
    assert legacy_entry.clip.x == new_entry.clip.x;
    assert legacy_entry.clip.y == new_entry.clip.y;
    assert legacy_entry.clip.width == new_entry.clip.width;
    assert legacy_entry.clip.height == new_entry.clip.height;
}


def _assert_wrapped_equal(p: _PNode, target_node: UiNode, id_str: str) -> None {
    legacy_entry = _entry_of(p.tables, target_node);
    new_entry = _frame_of(p.state).entries[id_str];
    assert len(legacy_entry.wrapped_lines) == len(new_entry.wrapped_lines);
    for i in range(len(legacy_entry.wrapped_lines)) {
        assert legacy_entry.wrapped_lines[i] == new_entry.wrapped_lines[i];
    }
}


test "shell parity holds across the full viewport matrix" {
    content: dict[str, list[str]] = {};
    content["header"] = ["Jackal"];
    content["status"] = ["ready"];
    content["prompt"] = ["> "];
    for vp in _viewports() {
        p = _build_shell(content);
        ok = _run_both(p, vp.columns, vp.rows);
        assert ok;
        for id_str in SHELL_IDS {
            target_node = p.nodes[id_str];
            _assert_rects_equal(p, target_node, id_str);
            _assert_clips_equal(p, target_node, id_str);
            _assert_wrapped_equal(p, target_node, id_str);
        }
    }
}


test "wrapped transcript and scroll clamp parity" {
    lines: list[str] = [];
    for i in range(50) {
        lines.append("line " + str(i) + " some trailing words here");
    }
    content: dict[str, list[str]] = {};
    content["header"] = ["Jackal"];
    content["transcript"] = lines;
    content["status"] = ["ready"];
    content["prompt"] = ["> "];

    for dims in [[80, 24], [40, 12]] {
        p = _build_shell(content);
        ok = _run_both(p, dims[0], dims[1]);
        assert ok;
        tnode = p.nodes["transcript"];
        _assert_rects_equal(p, tnode, "transcript");
        _assert_wrapped_equal(p, tnode, "transcript");

        # Scroll clamping: request far past the end on both engines.
        tid = node_id(p.nodes["transcript"]);
        legacy_set_scroll_offset(p.tables, p.nodes["transcript"], 500);
        set_scroll_offset(p.state, p.nodes["transcript"], 500);
        r2 = compute_layout(
            p.state, p.screen_node, Viewport(columns=dims[0], rows=dims[1])
        );
        assert r2.ok;
        legacy_entry = _entry_of(p.tables, p.nodes["transcript"]);
        published = r2.frame;
        if published is None {
            raise ValueError("missing frame");
        }
        new_entry = published.entries[tid];
        assert legacy_entry.scroll_offset == new_entry.scroll_offset;
        assert new_entry.scroll_offset == new_entry.max_scroll_offset;
    }
}


test "content matrix parity: empty, ascii, cjk, emoji, overwide, overtall" {
    samples: list[list[str]] = [
        [],
        ["plain ascii text"],
        ["中文宽度字符混排 mixed"],
        ["emoji 🙂👍 tail"],
        ["one very long line that certainly exceeds eighty columns of width"],
        ["r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10"],
    ];
    for sample in samples {
        content: dict[str, list[str]] = {};
        content["header"] = sample;
        content["transcript"] = sample;
        content["status"] = ["s"];
        content["prompt"] = ["> "];
        p = _build_shell(content);
        ok = _run_both(p, 80, 24);
        assert ok;
        for id_str in SHELL_IDS {
            target_node = p.nodes[id_str];
            _assert_rects_equal(p, target_node, id_str);
            _assert_wrapped_equal(p, target_node, id_str);
        }
    }
}


test "horizontal row container parity" {
    screen = MainScreen(key="main");
    header = Header(key="header");
    row = UiContainer(key="row");
    left = Header(key="left");
    mid = TranscriptView(key="mid");
    right = Status(key="right");
    status = Status(key="status");
    screen +>:Child(rank=1024):+> header;
    screen +>:Child(rank=2048):+> row;
    screen +>:Child(rank=3072):+> status;
    row +>:Child(rank=100):+> left;
    row +>:Child(rank=200):+> mid;
    row +>:Child(rank=300):+> right;

    tables = create_layout_tables();
    set_contract(tables, screen, intrinsic());
    set_contract(tables, header, fixed(None, 1));
    set_contract(tables, row, horizontal());
    set_contract(tables, left, fixed(20, None));
    set_contract(tables, mid, grow(1.0));
    set_contract(tables, right, fixed(10, 1));
    set_contract(tables, status, fixed(None, 1));

    state = create_layout_state(80, 24);
    set_spec(state, screen, LayoutSpec(width=_fillw(), height=_fillw()));
    set_spec(state, header, LayoutSpec(width=_fillw(), height=_fx(1.0)));
    # Row: full width, natural (max child) height like legacy INTRINSIC.
    set_spec(state, row, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(
        state,
        left,
        LayoutSpec(width=_fx(20.0), height=_fx(1.0), cross_align=Align.START),
    );
    set_spec(state, mid, LayoutSpec(width=_gr(1.0), height=_fillw()));
    set_spec(state, right, LayoutSpec(width=_fx(10.0), height=_fx(1.0)));
    set_spec(state, status, LayoutSpec(width=_fillw(), height=_fx(1.0)));

    legacy_measure_and_arrange(tables, screen, 80, 24);
    r = compute_layout(state, screen, Viewport(columns=80, rows=24));
    assert r.ok;

    pr: _PNode = _PNode(
        tables=tables,
        state=state,
        screen_node=screen,
        nodes={
            "screen": screen,
            "header": header,
            "row": row,
            "left": left,
            "mid": mid,
            "right": right,
            "status": status,
        },
    );
    for id_str in [
        "screen",
        "header",
        "row",
        "left",
        "mid",
        "right",
        "status",
    ] {
        target_node = pr.nodes[id_str];
        _assert_rects_equal(pr, target_node, id_str);
        _assert_clips_equal(pr, target_node, id_str);
    }
}


test "nested column with three grow children uses approved LR split" {
    screen = MainScreen(key="main");
    header = Header(key="header");
    body = UiContainer(key="body");
    pane_a = TranscriptView(key="a");
    pane_b = TranscriptView(key="b");
    pane_c = TranscriptView(key="c");
    status = Status(key="status");
    screen +>:Child(rank=1024):+> header;
    screen +>:Child(rank=2048):+> body;
    screen +>:Child(rank=3072):+> status;
    body +>:Child(rank=100):+> pane_a;
    body +>:Child(rank=200):+> pane_b;
    body +>:Child(rank=300):+> pane_c;

    tables = create_layout_tables();
    set_contract(tables, screen, intrinsic());
    set_contract(tables, header, fixed(None, 1));
    set_contract(tables, body, intrinsic());
    set_contract(tables, pane_a, grow(1.0));
    set_contract(tables, pane_b, grow(1.0));
    set_contract(tables, pane_c, grow(1.0));
    set_contract(tables, status, fixed(None, 1));

    state = create_layout_state(80, 24);
    set_spec(state, screen, LayoutSpec(width=_fillw(), height=_fillw()));
    set_spec(state, header, LayoutSpec(width=_fillw(), height=_fx(1.0)));
    set_spec(state, body, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state, pane_a, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state, pane_b, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state, pane_c, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state, status, LayoutSpec(width=_fillw(), height=_fx(1.0)));

    legacy_measure_and_arrange(tables, screen, 80, 24);
    r = compute_layout(state, screen, Viewport(columns=80, rows=24));
    assert r.ok;

    bid = node_id(body);
    legacy_body = _entry_of(tables, body);
    frame1 = r.frame;
    if frame1 is None {
        raise ValueError("missing frame");
    }
    new_body = frame1.entries[bid];
    assert legacy_body.rect.height == new_body.rect.height;

    # Approved correction zone (three fractional targets): assert exact
    # partition closure and sub-cell residuals, NOT strict equality.
    total = (
        frame1.entries[node_id(pane_a)].rect.height
        + frame1.entries[node_id(pane_b)].rect.height
        + frame1.entries[node_id(pane_c)].rect.height
    );
    assert total == new_body.rect.height;
    share = float(new_body.rect.height) / 3.0;
    for pid in [pane_a, pane_b, pane_c] {
        e = _frame_of(state).entries[node_id(pid)];
        assert abs(float(e.rect.height) - share) < 1.0;
    }
    # And it is genuinely the LR split, not the legacy leftover bias:
    # body height 21 -> thirds 7.0 exactly, but an odd span proves order.
    r2_legacy_tables = create_layout_tables();
    set_contract(r2_legacy_tables, screen, intrinsic());
    set_contract(r2_legacy_tables, header, fixed(None, 2));
    set_contract(r2_legacy_tables, body, intrinsic());
    set_contract(r2_legacy_tables, pane_a, grow(1.0));
    set_contract(r2_legacy_tables, pane_b, grow(1.0));
    set_contract(r2_legacy_tables, pane_c, grow(1.0));
    set_contract(r2_legacy_tables, status, fixed(None, 1));
    legacy_measure_and_arrange(r2_legacy_tables, screen, 80, 24);

    state2 = create_layout_state(80, 24);
    set_spec(state2, screen, LayoutSpec(width=_fillw(), height=_fillw()));
    set_spec(state2, header, LayoutSpec(width=_fillw(), height=_fx(2.0)));
    set_spec(state2, body, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state2, pane_a, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state2, pane_b, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state2, pane_c, LayoutSpec(width=_fillw(), height=_gr(1.0)));
    set_spec(state2, status, LayoutSpec(width=_fillw(), height=_fx(1.0)));
    r2 = compute_layout(state2, screen, Viewport(columns=80, rows=24));
    assert r2.ok;
    if r2.frame is None {
        raise ValueError("missing frame");
    }
    # 80x24: header 2 + status 1 -> body 21 -> 7.0 thirds; use 25 rows
    # instead for a fractional case via a second viewport below.

    # Fractional span: 80x26 -> body 23 -> targets 7.667 each.
    legacy_measure_and_arrange(r2_legacy_tables, screen, 80, 26);
    r3 = compute_layout(state2, screen, Viewport(columns=80, rows=26));
    assert r3.ok;
    if r3.frame is None {
        raise ValueError("missing frame");
    }
    b2 = r3.frame.entries[node_id(body)];
    assert b2.rect.height == 23;
    ha = r3.frame.entries[node_id(pane_a)].rect.height;
    hb = r3.frame.entries[node_id(pane_b)].rect.height;
    hc = r3.frame.entries[node_id(pane_c)].rect.height;
    assert ha + hb + hc == 23;
    # LR: floors [7,7,7], leftover 2 -> ranks a,b win -> [8,8,7].
    # Legacy bias-to-last would give [7,7,9].
    assert ha == 8;
    assert hb == 8;
    assert hc == 7;
}


test "overlay placement and clip parity" {
    for dims in [[80, 24], [20, 8]] {
        screen = MainScreen(key="main");
        overlay = ApprovalOverlay(key="ov");
        screen +>:Layer(z_index=10, modal=True):+> overlay;

        tables = create_layout_tables();
        set_contract(tables, screen, intrinsic());
        set_contract(tables, overlay, overlay_contract(14, 5));

        state = create_layout_state(dims[0], dims[1]);
        set_spec(state, screen, LayoutSpec(width=_fillw(), height=_fillw()));
        set_spec(
            state,
            overlay,
            LayoutSpec(width=_fx(14.0), height=_fx(5.0)),
        );

        legacy_measure_and_arrange(tables, screen, dims[0], dims[1]);
        r = compute_layout(state, screen, Viewport(columns=dims[0], rows=dims[1]));
        assert r.ok;

        oid = node_id(overlay);
        legacy_entry = _entry_of(tables, overlay);
        if r.frame is None {
            raise ValueError("missing frame");
        }
        new_entry = r.frame.entries[oid];
        assert legacy_entry.rect.x == new_entry.rect.x;
        assert legacy_entry.rect.y == new_entry.rect.y;
        assert legacy_entry.rect.width == new_entry.rect.width;
        assert legacy_entry.rect.height == new_entry.rect.height;
        assert legacy_entry.clip.x == new_entry.clip.x;
        assert legacy_entry.clip.width == new_entry.clip.width;
    }
}
