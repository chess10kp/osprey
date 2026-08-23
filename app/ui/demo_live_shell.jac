"""Interactive Jackal OSP shell — live ProcessTerminal session.

Crafted for presence: brand chrome, typewriter stream, visible caret,
Unicode progress, history, and a centered approval modal.

Keys:
  type / paste   edit draft
  enter          submit → stream → tool approval
  up / down      prompt history
  backspace      delete char
  ctrl+u         clear draft
  ctrl+l         redraw
  a / y          accept approval
  r / n          reject approval
  esc            dismiss approval, else quit
  ctrl+c         quit (terminal restored)

  JACPATH=. jac run ui/demo_live_shell.jac
"""

import sys;

import from ui.runtime {
    UiSession,
    create_session,
    dispose_session,
}

import from ui.screen {
    ShellScreen,
    build_main_shell,
    install_shell_contracts,
    shell_insert_text,
    shell_submit,
    shell_cancel,
    shell_open_approval,
    shell_close_approval,
    shell_resize,
}

import from ui.editor {
    editor_backspace,
    editor_history_prev,
    editor_history_next,
}

import from ui.transcript {
    TranscriptMessage,
    TranscriptProjection,
    bind_transcript,
    apply_transcript_revision,
    materialize_visible,
    set_follow_tail,
}

import from ui.layout_types {
    LayoutSpec,
    fill_axis,
    fixed_axis,
    grow_axis,
}

import from ui.renderer {
    Renderer,
    create_renderer,
    render_frame,
    set_node_content,
    set_node_contract,
    mark_semantic_dirty,
    mark_layout_dirty,
    request_cursor,
}

import from ui.terminal {
    ProcessTerminal,
    read_terminal_size,
}

import from ui.input {
    HostEvent,
    InputNormalizer,
    TextEvent,
    KeyEvent,
    PasteEvent,
    coalesce_events,
}

import from ui.progress_bar {
    ProgressBar,
    SetProgress,
}

import from ui.width {
    display_width,
    truncate_text,
}


glob SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];


obj LiveShell {
    has session: UiSession,
        shell: ShellScreen,
        proj: TranscriptProjection,
        renderer: Renderer,
        term: ProcessTerminal,
        normalizer: InputNormalizer,
        progress: ProgressBar,
        messages: list[TranscriptMessage] = [],
        rev: int = 0,
        msg_n: int = 0,
        phase: str = "ready",
        progress_value: float = 0.0,
        stream_full: str = "",
        stream_shown: int = 0,
        stream_msg_id: str = "",
        stream_tick: int = 0,
        spin_i: int = 0,
        running: bool = True,
        dirty: bool = True,
        columns: int = 80,
        rows: int = 24,
        status_hint: str = "enter · ↑↓ history · esc quit";
}


def _rule(width: int, ch: str = "─") -> str {
    if width < 1 {
        return "";
    }
    return ch * width;
}


def _pad_to(text: str, width: int) -> str {
    w = display_width(text);
    if w >= width {
        return truncate_text(text, width, ellipsis="…");
    }
    return text + (" " * (width - w));
}


"""Block progress meter — denser than ASCII #/-."""
def _meter(value: float, width: int) -> str {
    if width < 3 {
        return "▪" * max(0, width);
    }
    inner = width - 2;
    filled = int(max(0.0, min(1.0, value)) * float(inner));
    if filled > inner {
        filled = inner;
    }
    return "▐" + ("█" * filled) + ("░" * (inner - filled)) + "▌";
}


def _format_turn(role: str, body: str) -> str {
    if role == "user" {
        mark = "◆ you";
    } elif role == "assistant" {
        mark = "◇ jackal";
    } elif role == "tool" {
        mark = "▣ tool";
    } else {
        mark = "· system";
    }
    if not body {
        return mark;
    }
    indented = body.replace("\n", "\n  ");
    return mark + "\n  " + indented;
}


def _next_id(app: LiveShell) -> str {
    app.msg_n += 1;
    return "m" + str(app.msg_n);
}


def _commit_messages(app: LiveShell) {
    app.rev += 1;
    apply_transcript_revision(app.proj, app.rev, app.messages);
    app.dirty = True;
}


def _push_turn(app: LiveShell, role: str, body: str) -> str {
    mid = _next_id(app);
    app.messages = app.messages + [
        TranscriptMessage(
            message_id=mid,
            content=_format_turn(role, body),
            content_rev=1,
        )
    ];
    _commit_messages(app);
    return mid;
}


def _rewrite_turn(app: LiveShell, message_id: str, role: str, body: str) {
    updated: list[TranscriptMessage] = [];
    for message in app.messages {
        if message.message_id == message_id {
            updated.append(
                TranscriptMessage(
                    message_id=message_id,
                    content=_format_turn(role, body),
                    content_rev=message.content_rev + 1,
                )
            );
        } else {
            updated.append(message);
        }
    }
    app.messages = updated;
    _commit_messages(app);
}


def _install_layout(app: LiveShell) {
    # Mirror screen.jac configure_main_shell_layout (M6 LayoutSpec specs);
    # app.renderer's layout state carries the app.columns x app.rows viewport.
    set_node_contract(
        app.renderer,
        app.shell.screen,
        LayoutSpec(width=fill_axis(), height=fill_axis()),
    );
    set_node_contract(
        app.renderer,
        app.shell.header,
        LayoutSpec(width=fill_axis(), height=fixed_axis(2)),
    );
    set_node_contract(
        app.renderer,
        app.shell.transcript,
        LayoutSpec(width=fill_axis(), height=grow_axis(1.0), scroll_vertical=True),
    );
    set_node_contract(
        app.renderer,
        app.shell.status,
        LayoutSpec(width=fill_axis(), height=fixed_axis(1)),
    );
    set_node_contract(
        app.renderer,
        app.shell.prompt,
        LayoutSpec(width=fill_axis(), height=fixed_axis(3)),
    );
}


def _header_lines(app: LiveShell) -> list[str] {
    brand = " JACKAL ";
    tag = " osp live ";
    right = (
        str(app.columns)
        + "×"
        + str(app.rows)
        + "  r"
        + str(app.session.graph_revision)
    );
    mid_pad = app.columns - display_width(brand) - display_width(tag) - display_width(right) - 2;
    if mid_pad < 1 {
        mid_pad = 1;
    }
    top = brand + tag + (" " * mid_pad) + right;
    return [_pad_to(top, app.columns), _rule(app.columns, "━")];
}


def _status_line(app: LiveShell) -> str {
    spin = SPINNER[app.spin_i % len(SPINNER)];
    phase: str = app.phase;
    if app.phase == "streaming" {
        phase = spin + " stream";
    } elif app.phase == "approval" {
        phase = "◈ approve";
    } elif app.phase == "ready" {
        phase = "● ready";
    }
    meter = _meter(app.progress_value, 14);
    left = phase + "  " + meter;
    right = app.status_hint;
    gap = app.columns - display_width(left) - display_width(right) - 2;
    if gap < 1 {
        return truncate_text(left + "  " + right, app.columns, ellipsis="…");
    }
    return left + (" " * gap) + right;
}


def _prompt_lines(app: LiveShell) -> list[str] {
    draft = app.shell.prompt.draft;
    w = app.columns;
    top = "╭" + _rule(max(0, w - 2), "─") + "╮";
    body_inner = "❯ " + draft;
    body = "│" + _pad_to(body_inner, max(0, w - 2)) + "│";
    if app.phase == "streaming" {
        hint = "streaming — wait for jackal";
    } elif app.shell.approval is not None {
        hint = "modal — a accept · r reject";
    } else {
        hint = "enter send · ↑↓ history · ctrl+u clear";
    }
    hint = truncate_text(hint, max(0, w - 4), ellipsis="…");
    hint_w = display_width(hint);
    fill = max(0, w - 2 - hint_w);
    left = fill // 2;
    right = fill - left;
    foot = "╰" + ("─" * left) + hint + ("─" * right) + "╯";
    return [top, body, foot];
}


def _approval_lines(app: LiveShell) -> list[str] {
    _ = app;
    inner = 46;
    return [
        "╭" + _rule(inner, "─") + "╮",
        "│" + _pad_to("  TOOL APPROVAL", inner) + "│",
        "│" + _pad_to("", inner) + "│",
        "│" + _pad_to("  jac check  app/ui/renderer.jac", inner) + "│",
        "│" + _pad_to("  mode       read-only verify", inner) + "│",
        "│" + _pad_to("", inner) + "│",
        "│" + _pad_to("  [a] Accept    [r] Reject    [esc]", inner) + "│",
        "╰" + _rule(inner, "─") + "╯",
    ];
}


def _transcript_lines(app: LiveShell) -> list[str] {
    win = materialize_visible(app.proj);
    if win.lines {
        return win.lines;
    }
    # Empty-state composition — one quiet invitation.
    w = max(10, app.columns - 2);
    return [
        "",
        truncate_text("  the graph is live.", w, ellipsis="…"),
        truncate_text("  type below — jackal answers in this frame.", w, ellipsis="…"),
        "",
        truncate_text("  try:  explain retained damage", w, ellipsis="…"),
    ];
}


def _paint(app: LiveShell) {
    header = _header_lines(app);
    lines = _transcript_lines(app);
    status = _status_line(app);
    prompt_lines = _prompt_lines(app);

    if app.shell.approval is not None {
        overlay = _approval_lines(app);
        set_node_contract(
            app.renderer,
            app.shell.approval,
            LayoutSpec(width=fixed_axis(48), height=fixed_axis(len(overlay))),
        );
        set_node_content(app.renderer, app.shell.approval, overlay);
        mark_semantic_dirty(app.renderer, app.shell.approval);
        mark_layout_dirty(app.renderer, app.shell.approval);
    }

    set_node_content(app.renderer, app.shell.header, header);
    set_node_content(app.renderer, app.shell.transcript, lines);
    set_node_content(app.renderer, app.shell.status, [status]);
    set_node_content(app.renderer, app.shell.prompt, prompt_lines);
    mark_semantic_dirty(app.renderer, app.shell.header);
    mark_semantic_dirty(app.renderer, app.shell.transcript);
    mark_semantic_dirty(app.renderer, app.shell.status);
    mark_semantic_dirty(app.renderer, app.shell.prompt);
    mark_layout_dirty(app.renderer, app.shell.screen);

    # Caret sits after ❯ + space + draft inside the box (col 1 is │).
    draft_w = display_width(app.shell.prompt.draft);
    cursor_col = 1 + 2 + draft_w;  # │ + ❯␠ + draft
    max_col = app.columns - 2;
    if cursor_col > max_col {
        cursor_col = max_col;
    }
    request_cursor(app.renderer, app.shell.prompt, row_offset=1, col_offset=cursor_col);
}


def _render(app: LiveShell) {
    if not app.dirty {
        return;
    }
    _paint(app);
    frame = render_frame(app.renderer, app.shell.screen, app.term);
    if frame.cursor_row >= 0 {
        app.term.show_cursor();
    } else {
        app.term.hide_cursor();
    }
    app.dirty = False;
}


def _apply_resize(app: LiveShell, columns: int, rows: int) {
    if columns < 40 {
        columns = 40;
    }
    if rows < 12 {
        rows = 12;
    }
    if columns == app.columns and rows == app.rows {
        return;
    }
    app.columns = columns;
    app.rows = rows;
    shell_resize(app.session, app.shell, columns, rows);
    app.renderer = create_renderer(columns, rows);
    _install_layout(app);
    app.proj.viewport_width = max(12, columns - 2);
    app.proj.viewport_height = max(4, rows - 7);
    app.dirty = True;
}


def _begin_assistant_reply(app: LiveShell, user_text: str) {
    _push_turn(app, "user", user_text);
    app.phase = "streaming";
    app.shell.status.phase = "streaming";
    app.progress_value = 0.08;
    app.progress spawn SetProgress(value=app.progress_value);
    # Typewriter source — paced in _tick_stream.
    clipped = user_text if len(user_text) < 48 else user_text[:45] + "…";
    app.stream_full = (
        "looking at «"
        + clipped
        + "». walking Child ranks, measuring layout, "
        + "unioning damage rectangles — then a verify pass."
    );
    app.stream_shown = 0;
    app.stream_tick = 0;
    app.stream_msg_id = _push_turn(app, "assistant", "▍");
    app.status_hint = "streaming";
}


def _tick_stream(app: LiveShell) {
    if app.phase != "streaming" {
        return;
    }
    app.stream_tick += 1;
    app.spin_i += 1;
    step = 3;
    if app.stream_shown >= len(app.stream_full) {
        app.phase = "approval";
        app.shell.status.phase = "approval";
        app.progress_value = 0.72;
        app.progress spawn SetProgress(value=app.progress_value);
        shell_open_approval(app.session, app.shell);
        app.status_hint = "a accept · r reject";
        app.dirty = True;
        return;
    }
    app.stream_shown = min(len(app.stream_full), app.stream_shown + step);
    body = app.stream_full[:app.stream_shown];
    if app.stream_shown < len(app.stream_full) {
        body = body + "█";
    }
    _rewrite_turn(app, app.stream_msg_id, "assistant", body);
    frac = float(app.stream_shown) / float(max(1, len(app.stream_full)));
    app.progress_value = 0.08 + 0.55 * frac;
    app.progress spawn SetProgress(value=app.progress_value);
}


def _accept_approval(app: LiveShell) {
    if app.shell.approval is None {
        return;
    }
    shell_close_approval(app.session, app.shell);
    # Drop the block caret from the finished assistant line.
    _rewrite_turn(app, app.stream_msg_id, "assistant", app.stream_full);
    _push_turn(app, "tool", "jac check  ✓  clean (demo — no subprocess)");
    app.phase = "ready";
    app.shell.status.phase = "ready";
    app.progress_value = 1.0;
    app.progress spawn SetProgress(value=1.0);
    app.status_hint = "enter · ↑↓ history · esc quit";
    app.dirty = True;
}


def _reject_approval(app: LiveShell) {
    if app.shell.approval is None {
        return;
    }
    shell_close_approval(app.session, app.shell);
    _rewrite_turn(app, app.stream_msg_id, "assistant", app.stream_full);
    _push_turn(app, "tool", "jac check  ✗  cancelled");
    app.phase = "ready";
    app.shell.status.phase = "ready";
    app.progress_value = 0.0;
    app.progress spawn SetProgress(value=0.0);
    app.status_hint = "enter · ↑↓ history · esc quit";
    app.dirty = True;
}


"""Prompt history via the shared editor API (ui/editor.jac)."""
def _history_up(app: LiveShell) {
    editor_history_prev(app.shell.prompt);
    app.dirty = True;
}


def _history_down(app: LiveShell) {
    editor_history_next(app.shell.prompt);
    app.dirty = True;
}


def _handle_key(app: LiveShell, key: str) {
    if key == "ctrl+c" {
        app.running = False;
        return;
    }
    if key == "ctrl+l" {
        app.dirty = True;
        return;
    }
    if app.shell.approval is not None {
        if key == "a" or key == "y" or key == "enter" {
            _accept_approval(app);
            return;
        }
        if key == "r" or key == "n" {
            _reject_approval(app);
            return;
        }
        if key == "escape" {
            _reject_approval(app);
            return;
        }
        return;
    }
    if key == "escape" {
        app.running = False;
        return;
    }
    if key == "up" {
        if app.phase != "streaming" {
            _history_up(app);
        }
        return;
    }
    if key == "down" {
        if app.phase != "streaming" {
            _history_down(app);
        }
        return;
    }
    if key == "enter" {
        if app.phase == "streaming" {
            return;
        }
        text = app.shell.prompt.draft.strip();
        if not text {
            return;
        }
        shell_submit(app.session, app.shell);
        _begin_assistant_reply(app, text);
        return;
    }
    if key == "backspace" {
        if app.shell.prompt.draft {
            editor_backspace(app.shell.prompt);
            # Leave history-browse mode on manual edits (matches editor_insert).
            app.shell.prompt.history_index = -1;
            app.dirty = True;
        }
        return;
    }
    if key == "ctrl+u" {
        shell_cancel(app.session, app.shell);
        # Gap: neither AblePrompt.on_cancel nor shell_cancel resets history
        # state — no editor API op covers "clear draft + exit browse mode".
        app.shell.prompt.history_index = -1;
        app.dirty = True;
        return;
    }
    if key == "ctrl+d" {
        if not app.shell.prompt.draft {
            app.running = False;
        }
        return;
    }
}


def _handle_host_events(app: LiveShell, events: list[HostEvent]) {
    for event in coalesce_events(events) {
        if isinstance(event, TextEvent) {
            if app.shell.approval is not None {
                if event.text in ["a", "y", "r", "n"] {
                    _handle_key(app, event.text);
                }
                continue;
            }
            if app.phase == "streaming" {
                continue;
            }
            shell_insert_text(app.session, app.shell, event.text);
            app.dirty = True;
        } elif isinstance(event, KeyEvent) {
            _handle_key(app, event.key);
        } elif isinstance(event, PasteEvent) {
            if app.shell.approval is None and app.phase != "streaming" {
                shell_insert_text(app.session, app.shell, event.text);
                app.dirty = True;
            }
        }
    }
}


def create_live_shell() -> LiveShell {
    (cols, rows) = read_terminal_size(80, 24);
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    shell.header.title = "Jackal";
    install_shell_contracts(session, shell, "live.transcript");
    proj = bind_transcript(
        shell.transcript,
        "live.transcript",
        width=max(12, cols - 2),
        height=max(4, rows - 7),
    );
    set_follow_tail(proj, True);
    term = ProcessTerminal();
    term.columns = cols;
    term.rows = rows;
    renderer = create_renderer(cols, rows);
    progress = ProgressBar(key="live_progress", value=0.0);
    app = LiveShell(
        session=session,
        shell=shell,
        proj=proj,
        renderer=renderer,
        term=term,
        normalizer=InputNormalizer(),
        progress=progress,
        columns=cols,
        rows=rows,
    );
    _install_layout(app);
    _push_turn(
        app,
        "system",
        "session attached · detached graph · retained paint\n"
        + "say something — watch the stream, then the approval modal",
    );
    return app;
}


def run_live_shell_demo() {
    app = create_live_shell();
    app.term.start();
    app.term.set_title("Jackal");
    try {
        app.dirty = True;
        _render(app);
        while app.running {
            (cols, rows) = app.term.size();
            if cols != app.columns or rows != app.rows {
                _apply_resize(app, cols, rows);
            }
            raw = app.term.poll_input(0.04);
            if app.term.eof {
                app.running = False;
                break;
            }
            if raw {
                events = app.normalizer.feed(raw);
                _handle_host_events(app, events);
            } elif app.normalizer.buffer == "\x1b" {
                events = app.normalizer.flush_buffer();
                _handle_host_events(app, events);
            }
            if app.phase == "streaming" {
                _tick_stream(app);
            } elif app.phase == "approval" {
                # Keep the status meter alive while the modal sits.
                app.spin_i += 1;
                if app.spin_i % 4 == 0 {
                    app.dirty = True;
                }
            }
            _render(app);
        }
    } except KeyboardInterrupt {
        app.running = False;
    } finally {
        try {
            app.term.hide_cursor();
            app.term.stop();
        } except Exception {
        }
        dispose_session(app.session);
    }
}


with entry {
    if not sys.stdin.isatty() or not sys.stdout.isatty() {
        print("demo_live_shell needs a real TTY.");
        print("  JACPATH=. jac run ui/demo_live_shell.jac");
        raise SystemExit(1);
    }
    run_live_shell_demo();
}
