"""Behavior tests for the compute_layout pipeline (plan §7, M5 slice 1).

Same-stem test module: ui/layout_engine.jac symbols are ambient.
Covers: legacy-parity shell geometry, atomic publication, generation
monotonicity, resize reclamping, scroll clamping, overlay centering,
wrap-driven heights, degenerate viewports, and measurement-cache
invalidation through content revisions.
"""

import from ui.layout {
    AxisSize,
    LayoutFrame,
    LayoutError,
    LayoutSeverity,
    LayoutSpec,
    SizeMode,
    Viewport,
}
import from ui.layout_state {
    add_relation,
    create_layout_state,
    set_content,
    set_scroll_offset,
    set_spec,
}
import from ui.layout_state {
    LayoutState,
}
import from ui.model {
    ApprovalOverlay,
    Child,
    Layer,
    Header,
    MainScreen,
    Prompt,
    Status,
    TranscriptView,
    node_id,
}



def _published(state: LayoutState) -> LayoutFrame {
    f = state.last_frame;
    if f is None {
        raise ValueError("expected a published frame");
    }
    return f;
}


def _fill() -> AxisSize {
    return AxisSize(mode=SizeMode.FILL);
}


def _fixed(n: float) -> AxisSize {
    return AxisSize(mode=SizeMode.FIXED, preferred=n);
}


def _grow(weight: float) -> AxisSize {
    return AxisSize(mode=SizeMode.GROW, grow_weight=weight);
}


obj _ShellFixture {
    has state: LayoutState,
        screen: MainScreen,
        header: Header,
        transcript: TranscriptView,
        status: Status,
        prompt: Prompt;
}


def _shell(columns: int = 80, rows: int = 24) -> _ShellFixture {
    screen = MainScreen(key="main");
    header = Header(key="header");
    transcript = TranscriptView(key="transcript");
    status = Status(key="status");
    prompt = Prompt(key="prompt");
    screen +>:Child(rank=1024):+> header;
    screen +>:Child(rank=2048):+> transcript;
    screen +>:Child(rank=3072):+> status;
    screen +>:Child(rank=4096):+> prompt;

    state = create_layout_state(columns, rows);
    set_spec(state, screen, LayoutSpec(width=_fill(), height=_fill()));
    set_spec(state, header, LayoutSpec(width=_fill(), height=_fixed(1.0)));
    set_spec(
        state,
        transcript,
        LayoutSpec(width=_fill(), height=_grow(1.0), scroll_vertical=True),
    );
    set_spec(state, status, LayoutSpec(width=_fill(), height=_fixed(1.0)));
    set_spec(state, prompt, LayoutSpec(width=_fill(), height=_fixed(2.0)));
    set_content(state, header, ["Jackal"], 1);
    set_content(state, status, ["ready"], 1);
    set_content(state, prompt, ["> "], 1);
    return _ShellFixture(
        state=state,
        screen=screen,
        header=header,
        transcript=transcript,
        status=status,
        prompt=prompt,
    );
}


test "pipeline reproduces legacy-parity shell geometry at 80x24" {
    m = _shell();
    r = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert r.ok;
    assert r.frame is not None;

    hid = node_id(m.header);
    tid = node_id(m.transcript);
    sid = node_id(m.status);
    pid = node_id(m.prompt);

    fh = r.frame.entries[hid];
    assert fh.rect.x == 0;
    assert fh.rect.y == 0;
    assert fh.rect.width == 80;
    assert fh.rect.height == 1;

    ft = r.frame.entries[tid];
    assert ft.rect.y == 1;
    assert ft.rect.height == 20;
    assert ft.rect.width == 80;
    assert ft.measured.width == 80;
    assert ft.measured.height == 20;

    fs = r.frame.entries[sid];
    assert fs.rect.y == 21;
    assert fs.rect.height == 1;

    fp = r.frame.entries[pid];
    assert fp.rect.y == 22;
    assert fp.rect.height == 2;

    # Partition closure: children exactly fill the column.
    assert (
        fh.rect.height + ft.rect.height
        + fs.rect.height + fp.rect.height
    ) == 24;

    # Clips nest inside the viewport.
    assert ft.clip.width <= 80;
    assert ft.clip.height <= 20;

    assert r.frame.generation == 1;
    assert r.frame.overlay_ids == [];
}


test "publication replaces state.last_frame and generations advance" {
    m = _shell();
    r1 = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert r1.ok;
    assert m.state.last_frame is not None;
    assert _published(m.state).generation == 1;

    r2 = compute_layout(m.state, m.screen, Viewport(columns=100, rows=30));
    assert r2.ok;
    assert _published(m.state).generation == 2;
    assert _published(m.state).viewport.columns == 100;

    # Transcript reclamped into the resized column.
    tid = node_id(m.transcript);
    e = _published(m.state).entries[tid];
    assert e.rect.height == 26;
    assert e.rect.width == 100;
}


test "failed run leaves the prior published frame untouched" {
    m = _shell();
    r1 = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert r1.ok;
    published = m.state.last_frame;

    # A scoped node without a spec aborts compilation.
    stranger = Prompt(key="stranger");
    m.screen +>:Child(rank=9999):+> stranger;

    r2 = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert not r2.ok;
    assert len(r2.diagnostics) >= 1;
    assert m.state.last_frame is published;
    assert _published(m.state).generation == 1;
}


test "scroll offset clamps to wrapped height minus visible rows" {
    m = _shell();
    lines: list[str] = [];
    for i in range(50) {
        lines.append("line " + str(i));
    }
    set_content(m.state, m.transcript, lines, 1);
    set_scroll_offset(m.state, m.transcript, 500);

    r = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert r.ok;
    tid = node_id(m.transcript);
    e = _published(m.state).entries[tid];
    assert e.requested_scroll_offset == 500;
    assert e.max_scroll_offset == len(e.wrapped_lines) - 20;
    assert e.scroll_offset == e.max_scroll_offset;
}


test "wrapped content drives wrapped lines while fixed height clips" {
    m = _shell();
    long_line = "";
    for i in range(30) {
        long_line = long_line + "word ";
    }
    set_content(m.state, m.header, [long_line], 1);

    r = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert r.ok;
    hid = node_id(m.header);
    e = _published(m.state).entries[hid];
    assert e.rect.width == 80;
    # Content wraps at the quantized integer width...
    assert len(e.wrapped_lines) >= 2;
    # ...but the FIXED height still wins: overflow is clipped, not sized.
    assert e.measured.height == 1;
    assert e.clip.height <= 1;
}


test "centered fixed overlay lands at integer floor division" {
    screen = MainScreen(key="main");
    overlay = ApprovalOverlay(key="ov");
    screen +>:Layer(z_index=10, modal=True):+> overlay;

    state = create_layout_state(80, 24);
    set_spec(state, screen, LayoutSpec(width=_fill(), height=_fill()));
    set_spec(
        state,
        overlay,
        LayoutSpec(width=_fixed(20.0), height=_fixed(6.0)),
    );

    r = compute_layout(state, screen, Viewport(columns=80, rows=24));
    assert r.ok;
    oid = node_id(overlay);
    e = _published(state).entries[oid];
    assert e.rect.x == 30;  # (80 - 20) // 2
    assert e.rect.y == 9;   # (24 - 6) // 2
    assert e.rect.width == 20;
    assert e.rect.height == 6;
    assert _published(state).overlay_ids == [oid];
}


test "oversized fixed overlay keeps size and clips to viewport" {
    screen = MainScreen(key="main");
    overlay = ApprovalOverlay(key="big");
    screen +>:Layer(z_index=10, modal=True):+> overlay;

    state = create_layout_state(80, 24);
    set_spec(state, screen, LayoutSpec(width=_fill(), height=_fill()));
    set_spec(
        state,
        overlay,
        LayoutSpec(width=_fixed(120.0), height=_fixed(40.0)),
    );

    r = compute_layout(state, screen, Viewport(columns=80, rows=24));
    assert r.ok;
    e = _published(state).entries[node_id(overlay)];
    assert e.rect.width == 120;
    assert e.rect.height == 40;
    assert e.rect.x == 0;  # origin clamped
    assert e.rect.y == 0;
    assert e.clip.width == 80;
    assert e.clip.height == 24;
}


test "degenerate viewports stay satisfiable" {
    m = _shell();
    for vp in [Viewport(columns=0, rows=0), Viewport(columns=1, rows=1)] {
        r = compute_layout(m.state, m.screen, vp);
        assert r.ok;
        root_e = _published(m.state).entries[node_id(m.screen)];
        assert root_e.rect.width == vp.columns;
        assert root_e.rect.height == vp.rows;
    }
}


test "content revision bump rewraps through the measure cache" {
    m = _shell();
    set_content(m.state, m.transcript, ["short"], 1);
    r1 = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert r1.ok;
    tid = node_id(m.transcript);
    e1 = _published(m.state).entries[tid];
    assert len(e1.wrapped_lines) == 1;

    wide = "";
    for i in range(25) {
        wide = wide + "chunk ";
    }
    set_content(m.state, m.transcript, [wide], 2);
    r2 = compute_layout(m.state, m.screen, Viewport(columns=80, rows=24));
    assert r2.ok;
    e2 = _published(m.state).entries[tid];
    assert len(e2.wrapped_lines) >= 2;
}
