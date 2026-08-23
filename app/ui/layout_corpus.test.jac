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
    LayoutState,
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



import from ui.layout_corpus_cases {
    _case_shell_parity_holds_across_the_full_viewport_matrix,
    _case_wrapped_transcript_and_scroll_clamp_parity,
    _case_content_matrix_parity_empty_ascii_cjk_emoji_overwide_overtall,
    _case_horizontal_row_container_parity,
    _case_nested_column_with_three_grow_children_uses_approved_lr_split,
    _case_overlay_placement_and_clip_parity,
}

test "shell parity holds across the full viewport matrix" {
    _ = _case_shell_parity_holds_across_the_full_viewport_matrix();
}

test "wrapped transcript and scroll clamp parity" {
    _ = _case_wrapped_transcript_and_scroll_clamp_parity();
}

test "content matrix parity: empty, ascii, cjk, emoji, overwide, overtall" {
    _ = _case_content_matrix_parity_empty_ascii_cjk_emoji_overwide_overtall();
}

test "horizontal row container parity" {
    _ = _case_horizontal_row_container_parity();
}

test "nested column with three grow children uses approved LR split" {
    _ = _case_nested_column_with_three_grow_children_uses_approved_lr_split();
}

test "overlay placement and clip parity" {
    _ = _case_overlay_placement_and_clip_parity();
}
