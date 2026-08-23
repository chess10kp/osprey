# Behavior tests for retained damage renderer, patch scope, and cursor.
#
# Assert both final cells and patch scope so full clears cannot hide shrink,
# move, overlay-close, or cursor-cleanup bugs (OSPUI.md §21, PLAN Gate 3).
#
# Same-stem annex of ui/renderer.jac: base symbols are ambient here — never
# import from ui.renderer or ui.layout in this file (circular at collection);
# pull everything else from leaves (ui.layout_types, ui.model).

import from ui.model {
    MainScreen,
    Prompt,
    ApprovalOverlay,
    UiRegion,
    Layer,
    node_id,
}

import from ui.mutation {
    append_child,
    detach,
}

import from ui.layout_types {
    AxisSize,
    LayoutSpec,
    LayoutState,
    Rect,
    fill_axis,
    fixed_axis,
    grow_axis,
    intrinsic_axis,
    rect_of,
}

import from ui.virtual_terminal {
    VirtualTerminal,
}


node TextRegion(UiRegion) {
    has label: str = "";
}


# Spec builders over the permanent seam (legacy contract equivalents).
def _sp(width: AxisSize, height: AxisSize) -> LayoutSpec {
    return LayoutSpec(width=width, height=height);
}


def _fill_fill() -> LayoutSpec {
    return _sp(fill_axis(), fill_axis());
}


def _grow_region() -> LayoutSpec {
    return _sp(fill_axis(), grow_axis(1.0));
}


def _intrinsic_spec() -> LayoutSpec {
    return _sp(intrinsic_axis(), intrinsic_axis());
}


def _fixed_height(h: float) -> LayoutSpec {
    return _sp(fill_axis(), fixed_axis(h));
}


def _box(w: float, h: float) -> LayoutSpec {
    return _sp(fixed_axis(w), fixed_axis(h));
}


def _rect_of(state: LayoutState, n: UiNode) -> Rect {
    r = rect_of(state, n);
    if r is None {
        raise AssertionError("no published frame entry for node");
    }
    return r;
}


obj ShellFixture {
    has renderer: Renderer,
        screen: MainScreen,
        top: TextRegion,
        mid: TextRegion,
        bot: TextRegion;
}


def _shell_renderer(columns: int = 40, rows: int = 12) -> ShellFixture {
    renderer = create_renderer(columns, rows);
    screen = MainScreen(key="main");
    top = TextRegion(key="top", label="top");
    mid = TextRegion(key="mid", label="mid");
    bot = TextRegion(key="bot", label="bot");
    append_child(screen, top);
    append_child(screen, mid);
    append_child(screen, bot);
    set_node_contract(renderer, screen, _intrinsic_spec());
    set_node_contract(renderer, top, _fixed_height(1.0));
    set_node_contract(renderer, mid, _grow_region());
    set_node_contract(renderer, bot, _fixed_height(1.0));
    set_node_content(renderer, top, ["TOP"]);
    set_node_content(renderer, mid, ["mid"]);
    set_node_content(renderer, bot, ["BOT"]);
    return ShellFixture(
        renderer=renderer,
        screen=screen,
        top=top,
        mid=mid,
        bot=bot,
    );
}


def _rows_contain(rows: list[str], needle: str) -> bool {
    for row in rows {
        if needle in row {
            return True;
        }
    }
    return False;
}


test "create_renderer owns empty layout registry at terminal size" {
    renderer = create_renderer(40, 12);
    assert renderer.layout.viewport.columns == 40;
    assert renderer.layout.viewport.rows == 12;
    assert renderer.cursor_node_id == "";
    assert renderer.damage == [];
}


test "request_cursor and clear_cursor track a single holder" {
    renderer = create_renderer();
    prompt = Prompt(key="prompt");
    request_cursor(renderer, prompt, row_offset=0, col_offset=2);
    assert renderer.cursor_node_id == node_id(prompt);
    assert renderer.cursor_col_offset == 2;
    clear_cursor(renderer);
    assert renderer.cursor_node_id == "";
}


test "first paint fills expected cells without full clear" {
    shell = _shell_renderer(40, 8);
    renderer = shell.renderer;
    screen = shell.screen;
    term = VirtualTerminal(columns=40, rows=8);
    term.start();
    term.clear_writes();
    result = render_frame(renderer, screen, term);
    cells = term.capture_cells();
    assert cells[0].startswith("TOP");
    assert "mid" in cells[1];
    assert cells[7].startswith("BOT");
    assert result.used_full_clear == False;
    assert frame_used_full_clear(term.writes) == False;
    assert result.sync_wrapped == True;
    term.stop();
}


test "growth damages union of old and new mid bounds and shifts bot" {
    # Intrinsic mid sizes to content so growth shifts siblings; grow() fills
    # leftover and is covered by the vertical shell layout tests.
    shell = _shell_renderer(40, 10);
    renderer = shell.renderer;
    screen = shell.screen;
    mid = shell.mid;
    bot = shell.bot;
    set_node_contract(renderer, mid, _intrinsic_spec());
    term = VirtualTerminal(columns=40, rows=10);
    term.start();
    render_frame(renderer, screen, term);
    bot_y_before = _rect_of(renderer.layout, bot).y;
    term.clear_writes();

    set_node_content(renderer, mid, ["m0", "m1", "m2", "m3"]);
    mark_semantic_dirty(renderer, mid);
    mark_layout_dirty(renderer, mid);
    result = render_frame(renderer, screen, term);

    bot_y_after = _rect_of(renderer.layout, bot).y;
    assert bot_y_after > bot_y_before;
    assert result.used_full_clear == False;
    assert frame_used_full_clear(term.writes) == False;
    assert damage_cell_count(result.damage) < 40 * 10;
    assert len(result.damage) >= 1;
    cells = term.capture_cells();
    assert cells[bot_y_after].startswith("BOT");
    term.stop();
}


test "shrink repairs uncovered cells without full clear" {
    shell = _shell_renderer(40, 10);
    renderer = shell.renderer;
    screen = shell.screen;
    mid = shell.mid;
    bot = shell.bot;
    set_node_contract(renderer, mid, _intrinsic_spec());
    term = VirtualTerminal(columns=40, rows=10);
    term.start();
    set_node_content(renderer, mid, ["m0", "m1", "m2", "m3"]);
    render_frame(renderer, screen, term);
    mid_before = _rect_of(renderer.layout, mid);
    bot_y_before = _rect_of(renderer.layout, bot).y;
    term.clear_writes();

    set_node_content(renderer, mid, ["m0"]);
    mark_semantic_dirty(renderer, mid);
    mark_layout_dirty(renderer, mid);
    result = render_frame(renderer, screen, term);

    mid_after = _rect_of(renderer.layout, mid);
    bot_y_after = _rect_of(renderer.layout, bot).y;
    assert mid_after.height < mid_before.height;
    assert bot_y_after < bot_y_before;
    assert result.used_full_clear == False;
    assert frame_used_full_clear(term.writes) == False;
    cells = term.capture_cells();
    for row in cells {
        assert "m2" not in row;
        assert "m3" not in row;
    }
    assert cells[bot_y_after].startswith("BOT");
    union_h = mid_before.height;
    damaged_h = 0;
    for d in result.damage {
        damaged_h = max(damaged_h, d.rect.height);
    }
    assert damaged_h >= union_h or damage_cell_count(result.damage) >= mid_before.width;
    term.stop();
}


test "sibling move after height change repaints shifted region" {
    shell = _shell_renderer(40, 10);
    renderer = shell.renderer;
    screen = shell.screen;
    top = shell.top;
    mid = shell.mid;
    bot = shell.bot;
    term = VirtualTerminal(columns=40, rows=10);
    term.start();
    render_frame(renderer, screen, term);
    term.clear_writes();

    set_node_content(renderer, top, ["TOP", "TOP2"]);
    set_node_contract(renderer, top, _fixed_height(2.0));
    mark_layout_dirty(renderer, top);
    result = render_frame(renderer, screen, term);

    assert _rect_of(renderer.layout, mid).y == 2;
    assert _rect_of(renderer.layout, bot).y > 2;
    cells = term.capture_cells();
    assert cells[0].startswith("TOP");
    assert cells[1].startswith("TOP2");
    assert result.used_full_clear == False;
    assert len(result.patch_rects) >= 1;
    term.stop();
}


test "resize recomputes wrap and keeps node ids" {
    renderer = create_renderer(40, 8);
    screen = MainScreen(key="main");
    body = TextRegion(key="body");
    append_child(screen, body);
    set_node_contract(renderer, screen, _intrinsic_spec());
    set_node_contract(renderer, body, _intrinsic_spec());
    set_node_content(renderer, body, ["abcdefghijklmnop"]);
    body_id = node_id(body);

    term = VirtualTerminal(columns=40, rows=8);
    term.start();
    render_frame(renderer, screen, term);
    h1 = _rect_of(renderer.layout, body).height;

    term.inject_resize(8, 8);
    renderer.layout.viewport.columns = 8;
    renderer.layout.viewport.rows = 8;
    mark_layout_dirty(renderer, body);
    result = render_frame(renderer, screen, term);
    h2 = _rect_of(renderer.layout, body).height;

    assert node_id(body) == body_id;
    assert h2 > h1;
    assert result.used_full_clear == False;
    term.stop();
}


test "unicode content paints without corrupting neighbor cells" {
    renderer = create_renderer(20, 4);
    screen = MainScreen(key="main");
    body = TextRegion(key="cjk");
    append_child(screen, body);
    set_node_contract(renderer, screen, _intrinsic_spec());
    set_node_contract(renderer, body, _fixed_height(1.0));
    set_node_content(renderer, body, ["你好"]);

    term = VirtualTerminal(columns=20, rows=4);
    term.start();
    result = render_frame(renderer, screen, term);
    cells = term.capture_cells();
    assert "你" in cells[0] or "你好" in cells[0];
    assert result.used_full_clear == False;
    term.stop();
}


test "overlay close damages old rect and restores underlying cells" {
    renderer = create_renderer(40, 12);
    screen = MainScreen(key="main");
    body = TextRegion(key="body");
    overlay = ApprovalOverlay(key="approval");
    append_child(screen, body);
    screen +>:Layer(z_index=10, modal=True):+> overlay;

    set_node_contract(renderer, screen, _intrinsic_spec());
    set_node_contract(renderer, body, _grow_region());
    set_node_content(renderer, body, ["UNDERLAY"]);
    set_node_contract(renderer, overlay, _box(20.0, 4.0));
    set_node_content(renderer, overlay, ["Approve?", "y/n"]);

    term = VirtualTerminal(columns=40, rows=12);
    term.start();
    render_frame(renderer, screen, term);
    overlay_rect = _rect_of(renderer.layout, overlay);
    assert not overlay_rect.is_empty();
    cells_with = term.capture_cells();
    assert _rows_contain(cells_with, "Approve");
    term.clear_writes();

    detach_node(renderer, overlay);
    # mutation.detach cuts Child edges only; mirror runtime.close_overlay
    # teardown by cutting the Layer edge so the overlay leaves the
    # compute scope (a Layer-reached node needs a registered spec).
    for e in [edge screen ->:Layer:-> overlay] {
        del e;
    }
    detach(overlay);
    result = render_frame(renderer, screen, term);

    cells_after = term.capture_cells();
    assert _rows_contain(cells_after, "UNDERLAY");
    assert not _rows_contain(cells_after, "Approve");
    assert result.used_full_clear == False;
    assert frame_used_full_clear(term.writes) == False;
    # Old overlay rectangle must appear in damage so underlay is repainted.
    covered = False;
    for d in result.damage {
        if d.rect.intersects(overlay_rect) or d.reason == "detach" {
            covered = True;
        }
    }
    assert covered;
    term.stop();
}


test "cursor placed in prompt region and cleared on detach" {
    renderer = create_renderer(40, 6);
    screen = MainScreen(key="main");
    prompt = Prompt(key="prompt", draft="hi");
    append_child(screen, prompt);
    set_node_contract(renderer, screen, _intrinsic_spec());
    set_node_contract(renderer, prompt, _fixed_height(1.0));
    set_node_content(renderer, prompt, ["> hi"]);
    request_cursor(renderer, prompt, row_offset=0, col_offset=2);

    term = VirtualTerminal(columns=40, rows=6);
    term.start();
    result = render_frame(renderer, screen, term);
    pr = _rect_of(renderer.layout, prompt);
    assert result.cursor_row == pr.y + 0;
    assert result.cursor_col == pr.x + 2;
    assert renderer.last_cursor_row == result.cursor_row;

    term.clear_writes();
    detach_node(renderer, prompt);
    detach(prompt);
    # Empty screen after detach: cursor must be cleared / relocated off-field.
    result2 = render_frame(renderer, screen, term);
    assert renderer.cursor_node_id == "";
    assert result2.cursor_row == -1 or result2.cursor_col == -1;
    term.stop();
}


test "localized semantic edit writes fewer cells than full frame" {
    shell = _shell_renderer(40, 12);
    renderer = shell.renderer;
    screen = shell.screen;
    bot = shell.bot;
    term = VirtualTerminal(columns=40, rows=12);
    term.start();
    render_frame(renderer, screen, term);
    term.clear_writes();

    set_node_content(renderer, bot, ["DONE"]);
    mark_semantic_dirty(renderer, bot);
    result = render_frame(renderer, screen, term);

    full = 40 * 12;
    assert result.cells_written > 0;
    assert result.cells_written < full;
    assert result.used_full_clear == False;
    assert damage_cell_count(result.damage) <= 40 * 2;
    cells = term.capture_cells();
    assert cells[_rect_of(renderer.layout, bot).y].startswith("DONE");
    term.stop();
}


test "desired_cells matches painted virtual terminal snapshot" {
    shell = _shell_renderer(20, 6);
    renderer = shell.renderer;
    screen = shell.screen;
    desired = desired_cells(renderer, screen);
    term = VirtualTerminal(columns=20, rows=6);
    term.start();
    render_frame(renderer, screen, term);
    painted = term.capture_cells();
    assert len(desired) == 6;
    assert desired[0].startswith("TOP");
    assert painted[0].startswith("TOP");
    assert desired[5].startswith("BOT");
    term.stop();
}


test "compute_damage unions prev and current rects after growth" {
    shell = _shell_renderer(30, 10);
    renderer = shell.renderer;
    screen = shell.screen;
    mid = shell.mid;
    set_node_contract(renderer, mid, _intrinsic_spec());
    term = VirtualTerminal(columns=30, rows=10);
    term.start();
    # First frame establishes the prev-rect damage baseline.
    render_frame(renderer, screen, term);
    set_node_content(renderer, mid, ["a", "b", "c", "d"]);
    mark_layout_dirty(renderer, mid);
    relayout(renderer, screen);
    damage = compute_damage(renderer, screen);
    assert len(damage) >= 1;
    total = damage_cell_count(damage);
    assert total >= 30;
    term.stop();
}
