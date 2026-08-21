"""Behavior tests for retained layout contracts, measure, and arrange.

These tests define Unit 6 acceptance for layout.jac. Core measure/arrange is
stubbed until implementation; geometry helpers and the API surface are fixed.
"""

import from ui.model {
    MainScreen,
    Header,
    TranscriptView,
    Status,
    Prompt,
    ApprovalOverlay,
    UiContainer,
    UiRegion,
    Layer,
    node_id,
}

import from ui.mutation {
    append_child,
}


node TextRegion(UiRegion) {
    has label: str = "";
}


node RowContainer(UiContainer) {}


test "rect_union covers growth and movement bounds" {
    a = Rect(x=0, y=0, width=10, height=2);
    b = Rect(x=0, y=1, width=10, height=3);
    u = rect_union(a, b);
    assert u.x == 0;
    assert u.y == 0;
    assert u.width == 10;
    assert u.height == 4;

    moved = Rect(x=0, y=3, width=10, height=2);
    u2 = rect_union(a, moved);
    assert u2.y == 0;
    assert u2.height == 5;
}


test "rect helpers detect empty and intersection" {
    empty = Rect();
    assert empty.is_empty();
    a = Rect(x=0, y=0, width=5, height=2);
    b = Rect(x=4, y=1, width=3, height=2);
    c = Rect(x=10, y=10, width=1, height=1);
    assert a.intersects(b);
    assert not a.intersects(c);
    assert a.contains_point(0, 0);
    assert not a.contains_point(5, 0);
}


test "layout contract factories set expected kinds" {
    assert fixed(width=80, height=1).kind == LayoutKind.FIXED;
    assert intrinsic().kind == LayoutKind.INTRINSIC;
    assert bounded(min_height=1, max_height=5).kind == LayoutKind.BOUNDED;
    assert grow(2.0).kind == LayoutKind.GROW;
    assert grow(2.0).grow_weight == 2.0;
    assert viewport().kind == LayoutKind.VIEWPORT;
    assert overlay_contract(40, 10).kind == LayoutKind.OVERLAY;
    assert horizontal().axis == "horizontal";
}


test "side tables store contracts and content by stable node id" {
    tables = create_layout_tables(40, 12);
    prompt = Prompt(key="prompt", draft="hi");
    pid = node_id(prompt);
    set_contract(tables, prompt, fixed(height=2));
    set_content(tables, prompt, ["> hi"]);
    entry = get_entry(tables, prompt);
    assert entry is not None;
    assert entry.contract.kind == LayoutKind.FIXED;
    assert entry.contract.fixed_height == 2;
    assert tables.content[pid] == ["> hi"];
    assert entry.semantic_dirty;
    assert entry.layout_dirty;
}


test "clear_node removes layout and content entries" {
    tables = create_layout_tables();
    status = Status(key="status", phase="ready");
    set_contract(tables, status, fixed(height=1));
    set_content(tables, status, ["ready"]);
    clear_node(tables, status);
    assert get_entry(tables, status) is None;
    assert node_id(status) not in tables.content;
}


test "vertical shell stacks header transcript status prompt" {
    tables = create_layout_tables(40, 20);
    screen = MainScreen(key="main");
    header = Header(key="header", title="Jackal");
    transcript = TranscriptView(key="transcript");
    status = Status(key="status", phase="ready");
    prompt = Prompt(key="prompt");

    append_child(screen, header);
    append_child(screen, transcript);
    append_child(screen, status);
    append_child(screen, prompt);

    set_contract(tables, screen, intrinsic());
    set_contract(tables, header, fixed(height=1));
    set_contract(tables, transcript, grow());
    set_contract(tables, status, fixed(height=1));
    set_contract(tables, prompt, fixed(height=2));
    set_content(tables, header, ["Jackal"]);
    set_content(tables, transcript, ["line0", "line1", "line2"]);
    set_content(tables, status, ["ready"]);
    set_content(tables, prompt, ["> ", ""]);

    measure_and_arrange(tables, screen, 40, 20);

    hr = rect_of(tables, header);
    tr = rect_of(tables, transcript);
    sr = rect_of(tables, status);
    pr = rect_of(tables, prompt);

    assert hr.x == 0 and hr.y == 0 and hr.width == 40 and hr.height == 1;
    assert tr.y == 1;
    assert tr.height >= 3;
    assert sr.y == tr.bottom();
    assert sr.height == 1;
    assert pr.y == sr.bottom();
    assert pr.height == 2;
    assert pr.bottom() <= 20;
    # Grow fills remaining vertical space between header and status/prompt.
    assert tr.height == 20 - 1 - 1 - 2;
}


test "intrinsic height follows wrapped content width" {
    tables = create_layout_tables(10, 20);
    screen = MainScreen(key="main");
    body = TextRegion(key="body", label="body");
    append_child(screen, body);
    set_contract(tables, screen, intrinsic());
    set_contract(tables, body, intrinsic());
    set_content(tables, body, ["abcdefghijKLMNO"]);

    measure_and_arrange(tables, screen, 10, 20);
    br = rect_of(tables, body);
    assert br.width == 10;
    # "abcdefghij" + "KLMNO" => two wrapped lines at width 10
    assert br.height == 2;
    assert measured_of(tables, body).height == 2;
}


test "bounded contract clamps measured height" {
    tables = create_layout_tables(20, 30);
    screen = MainScreen(key="main");
    body = TextRegion(key="body");
    append_child(screen, body);
    set_contract(tables, screen, intrinsic());
    set_contract(tables, body, bounded(min_height=2, max_height=3));
    set_content(tables, body, ["a", "b", "c", "d", "e"]);

    measure_and_arrange(tables, screen, 20, 30);
    assert rect_of(tables, body).height == 3;
}


test "unicode wide characters affect wrap height" {
    tables = create_layout_tables(4, 10);
    screen = MainScreen(key="main");
    body = TextRegion(key="cjk");
    append_child(screen, body);
    set_contract(tables, screen, intrinsic());
    set_contract(tables, body, intrinsic());
    # Each CJK char is 2 columns; four chars need two lines at width 4.
    set_content(tables, body, ["你好世界"]);

    measure_and_arrange(tables, screen, 4, 10);
    assert rect_of(tables, body).height == 2;
}


test "viewport clips content and records clip rect" {
    tables = create_layout_tables(20, 6);
    screen = MainScreen(key="main");
    vp = TextRegion(key="vp");
    append_child(screen, vp);
    set_contract(tables, screen, intrinsic());
    set_contract(tables, vp, viewport());
    set_content(tables, vp, ["0", "1", "2", "3", "4", "5", "6", "7"]);
    set_scroll_offset(tables, vp, 2);

    measure_and_arrange(tables, screen, 20, 6);
    vr = rect_of(tables, vp);
    assert vr.height == 6;
    assert vr.width == 20;
    entry = get_entry(tables, vp);
    assert entry is not None;
    assert entry.clip.height == 6;
    assert not entry.clip.is_empty();
}


test "horizontal fragments share one row" {
    tables = create_layout_tables(40, 5);
    screen = MainScreen(key="main");
    row = RowContainer(key="status-row");
    left = TextRegion(key="phase");
    right = TextRegion(key="model");
    append_child(screen, row);
    append_child(row, left);
    append_child(row, right);

    set_contract(tables, screen, intrinsic());
    set_contract(tables, row, horizontal());
    set_contract(tables, left, fixed(width=10, height=1));
    set_contract(tables, right, grow());
    set_content(tables, left, ["ready"]);
    set_content(tables, right, ["sonnet"]);

    measure_and_arrange(tables, screen, 40, 5);
    lr = rect_of(tables, left);
    rr = rect_of(tables, right);
    assert lr.y == rr.y;
    assert lr.height == 1 and rr.height == 1;
    assert lr.x == 0 and lr.width == 10;
    assert rr.x == 10;
    assert rr.width == 30;
}


test "resize recomputes geometry without replacing node ids" {
    tables = create_layout_tables(40, 12);
    screen = MainScreen(key="main");
    body = TextRegion(key="body");
    append_child(screen, body);
    set_contract(tables, screen, intrinsic());
    set_contract(tables, body, intrinsic());
    set_content(tables, body, ["abcdefghijklmnop"]);
    body_id = node_id(body);

    measure_and_arrange(tables, screen, 40, 12);
    h_wide = rect_of(tables, body).height;

    measure_and_arrange(tables, screen, 8, 12);
    h_narrow = rect_of(tables, body).height;
    assert node_id(body) == body_id;
    assert h_narrow > h_wide;
}


test "overlay contract places overlay on screen without Child flow height" {
    tables = create_layout_tables(40, 20);
    screen = MainScreen(key="main");
    body = TextRegion(key="body");
    overlay = ApprovalOverlay(key="approval");
    append_child(screen, body);
    screen +>:Layer(z_index=10, modal=True):+> overlay;

    set_contract(tables, screen, intrinsic());
    set_contract(tables, body, grow());
    set_content(tables, body, ["under"]);
    set_contract(tables, overlay, overlay_contract(20, 5));
    set_content(tables, overlay, ["Approve?", "[y/n]"]);

    measure_and_arrange(tables, screen, 40, 20);
    br = rect_of(tables, body);
    or_ = rect_of(tables, overlay);
    assert br.height == 20;
    assert or_.width == 20;
    assert or_.height == 5;
    # Overlay is centered or top-anchored within the screen; must be on-screen.
    assert or_.x >= 0 and or_.right() <= 40;
    assert or_.y >= 0 and or_.bottom() <= 20;
}


test "snapshot_rects preserves previous bounds for damage" {
    tables = create_layout_tables(20, 10);
    screen = MainScreen(key="main");
    body = TextRegion(key="body");
    append_child(screen, body);
    set_contract(tables, screen, intrinsic());
    set_contract(tables, body, fixed(height=2));
    set_content(tables, body, ["a", "b"]);
    measure_and_arrange(tables, screen, 20, 10);
    snapshot_rects(tables);
    set_contract(tables, body, fixed(height=4));
    set_content(tables, body, ["a", "b", "c", "d"]);
    measure_and_arrange(tables, screen, 20, 10);
    entry = get_entry(tables, body);
    assert entry is not None;
    assert entry.prev_rect.height == 2;
    assert entry.rect.height == 4;
}
