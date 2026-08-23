"""Jackal TUI - the product terminal surface.

Same differential-renderer shell as the demo, driven by the REAL agent:
submit runs run_turn on a worker thread; its events (chunks, tool calls,
errors) flow through a thread-safe queue into the transcript. esc during a
turn cooperatively aborts it (cancel_active_turn); extensions load per
.jackal/extensions.json at boot.

Agent-side seam only - painting/layout belong to ui/demo_live_shell.jac
(upstream of this file). If you change paint behavior, change it there.
"""

import sys;
import threading;
import queue;
import from agent.session {
    run_turn,
    session_boot,
    cancel_active_turn,
    model,
    set_model,
    clear_history,
    restore_history,
    get_history,
    list_commands,
    run_command,
    plugins,
    new_session_id,
}
import from agent.modes { requires_approval }
import from agent.plugin_bridge {
    poll_ui_request,
    respond_ui,
    cancel_ui,
}
import from agent.sessions {
    list_sessions,
    latest_session_id,
    get_session_record,
    export_session,
    save_session,
    is_valid_session_id,
}
import os;

import from ui.runtime {
    UiSession,
    create_session,
    dispose_session,
}

import from ui.screen {
    ShellScreen,
    build_main_shell,
    configure_main_shell_layout,
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

import from ui.layout {
    LayoutSpec,
    OverlayAnchor,
    fill_axis,
    fixed_axis,
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
        status_hint: str = "enter · ↑↓ history · esc quit",
        evq: any = None,
        worker: any = None,
        tool_msg_id: str = "",
        appr_event: any = None,
        appr_approved: bool = False,
        appr_tool: str = "",
        ui_modal: any = None,
        cmd_q: any = None;
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
    # Permanent shell specs first (screen fill/fill, transcript grow+scroll,
    # status/prompt legacy heights), then this shell's parity overrides:
    # header 2 rows, prompt 3 rows (mirrors the pre-M6 contracts).
    configure_main_shell_layout(app.renderer.layout, app.shell);
    set_node_contract(
        app.renderer,
        app.shell.header,
        LayoutSpec(width=fill_axis(), height=fixed_axis(2)),
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


"""Foreground extension-ui modal content — painted into the shared
overlay node while app.ui_modal is set."""
def _ui_modal_lines(app: LiveShell) -> list[str] {
    m: any = app.ui_modal;
    inner = 46;
    method = str(m.get("method", ""));
    head = "? [ui] " + method.upper();
    body: list[str] = [];
    title = str(m.get("title", ""));
    message = str(m.get("message", ""));
    placeholder = str(m.get("placeholder", ""));
    if title {
        body.append(title[:inner - 4]);
    }
    if message {
        body.append(message[:inner - 4]);
    }
    body.append("");
    if method == "select" {
        options: list = list(m.get("options", []));
        sel = int(m.get("selected", 0));
        i = 0;
        for opt in options[:8] {
            mark = ">" if i == sel else " ";
            body.append(mark + " " + str(opt)[:inner - 6]);
            i += 1;
        }
        body.append("");
        body.append("  [\u2191\u2193] move   [enter] choose   [esc] cancel");
    } elif method == "confirm" {
        body.append("  [y] yes    [n/Esc] no");
    } else {
        draft = str(m.get("draft", ""));
        shown = draft if draft else placeholder;
        body.append("  > " + shown[:inner - 6] + "\u258c");
        body.append("");
        body.append("  [enter] submit (empty allowed)   [esc] cancel");
    }
    lines: list[str] = ["\u256d" + _rule(inner, "\u2500") + "\u256e"];
    lines.append("\u2502" + _pad_to("  " + head, inner) + "\u2502");
    for ln in body {
        lines.append("\u2502" + _pad_to("  " + ln, inner) + "\u2502");
    }
    lines.append("\u2570" + _rule(inner, "\u2500") + "\u256f");
    return lines;
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

    if app.ui_modal is not None {
        # Extension modal owns the shared overlay node while open.
        overlay2 = _ui_modal_lines(app);
        set_node_contract(
            app.renderer,
            app.shell.approval,
            LayoutSpec(
                width=fixed_axis(48),
                height=fixed_axis(len(overlay2)),
                overlay_anchor=OverlayAnchor.CENTER,
            ),
        );
        set_node_content(app.renderer, app.shell.approval, overlay2);
        mark_semantic_dirty(app.renderer, app.shell.approval);
        mark_layout_dirty(app.renderer, app.shell.approval);
    } elif app.shell.approval is not None {
        overlay = _approval_lines(app);
        set_node_contract(
            app.renderer,
            app.shell.approval,
            LayoutSpec(
                width=fixed_axis(48),
                height=fixed_axis(len(overlay)),
                overlay_anchor=OverlayAnchor.CENTER,
            ),
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


"""Launch the real agent turn on a worker thread.

Events flow through app.evq as (kind, data) pairs consumed by _tick_stream;
the worker is a daemon so esc/quit never hangs on a stuck transport."""
def _begin_assistant_reply(app: LiveShell, user_text: str) {
    _push_turn(app, "user", user_text);
    app.phase = "streaming";
    app.shell.status.phase = "streaming";
    app.progress_value = 0.05;
    app.progress spawn SetProgress(value=app.progress_value);
    app.stream_full = "";
    app.stream_shown = 0;
    app.stream_tick = 0;
    # Capture the queue LOCALLY: _finish_stream nulls app.evq when the turn
    # ends, and late worker events must never dereference that field.
    q = queue.Queue();
    app.evq = q;
    app.stream_msg_id = _push_turn(app, "assistant", "▍");
    app.status_hint = "streaming · esc abort";

    def collector(kind: str, data: dict) {
        try {
            q.put((str(kind), dict(data)));
        } except Exception {
        }
    }

    # Tool approver: auto-allow read-only tools; destructive ones raise the
    # modal and block the WORKER thread on an Event until the UI resolves it.
    def approve(name: str, args: dict) -> any {
        cmd = "";
        if isinstance(args, dict) {
            cmd = str(args.get("cmd", ""));
        }
        policy = requires_approval("normal", name, cmd);
        if policy == "auto" {
            return True;
        }
        if policy != "confirm" {
            return "blocked in normal mode";
        }
        q.put(("__approve__", {"tool": name, "args": args}));
        ev = threading.Event();
        app.appr_event = ev;
        app.appr_approved = False;
        approved = ev.wait(600.0);
        app.appr_event = None;
        if not approved or not app.appr_approved {
            return "denied by user";
        }
        return True;
    }

    def worker_main {
        try {
            answer = run_turn(user_text, collector, approve=approve);
            q.put(("__done__", {"answer": str(answer)}));
        } except Exception as e {
            try {
                q.put(("error", {"message": str(e)}));
            } except Exception {
            }
            q.put(("__done__", {"answer": ""}));
        }
    }

    app.worker = threading.Thread(target=worker_main, daemon=True);
    app.worker.start();
}


def _finish_stream(app: LiveShell, final_body: str) {
    body = final_body if final_body else app.stream_full;
    if not body.strip() {
        body = "(no response)";
    }
    _rewrite_turn(app, app.stream_msg_id, "assistant", body.rstrip());
    app.phase = "ready";
    app.shell.status.phase = "ready";
    app.progress_value = 0.0;
    app.progress spawn SetProgress(value=0.0);
    app.status_hint = "enter · ↑↓ history · esc quit";
    app.worker = None;
    app.evq = None;
    app.dirty = True;
}


def _tick_stream(app: LiveShell) {
    if app.phase != "streaming" or app.evq is None {
        return;
    }
    app.spin_i += 1;
    drained = False;
    while True {
        try {
            item: any = app.evq.get_nowait();
        } except queue.Empty {
            break;
        }
        kind = str(item[0]);
        data: any = item[1];
        drained = True;
        if kind == "chunk" {
            app.stream_full = app.stream_full + str(data.get("content", ""));
            body = app.stream_full + "█";
            _rewrite_turn(app, app.stream_msg_id, "assistant", body);
        } elif kind == "tool_call" {
            args: any = data.get("args", {});
            parts: list[str] = [];
            for pair in args.items() {
                parts.append(str(pair[0]) + "=" + str(pair[1])[:40]);
            }
            summary = str(data.get("tool", "")) + "(" + (", ".join(parts))[:120] + ")";
            app.tool_msg_id = _push_turn(app, "tool", "* " + summary);
            _rewrite_turn(app, app.tool_msg_id, "tool", "* " + summary);
        } elif kind == "tool_result" {
            preview = str(data.get("result", ""))[:200].replace("\n", " ");
            _push_turn(app, "tool", "  -> " + preview);
        } elif kind == "retry" {
            note = "retry " + str(data.get("attempt", "?")) + "/" + str(data.get("max_retries", "?"));
            _push_turn(app, "tool", "~ " + note + ": " + str(data.get("message", ""))[:80]);
        } elif kind == "cancelled" {
            app.stream_full = app.stream_full + "\n[cancelled]";
            _finish_stream(app, app.stream_full);
            return;
        } elif kind == "loop_limit" {
            _push_turn(app, "tool", "! iteration limit reached");
        } elif kind == "extensions" {
            label = str(data.get("label", ""));
            if label {
                _push_turn(app, "tool", "[ " + label + " ]");
            }
        } elif kind == "entry" {
            _push_turn(app, "tool", "+ " + str(data.get("type", "entry")) + " " + str(data.get("content", ""))[:100]);
        } elif kind == "error" {
            msg = str(data.get("message", "unknown error"));
            _rewrite_turn(app, app.stream_msg_id, "assistant", "ERROR: " + msg[:400]);
            _finish_stream(app, "ERROR: " + msg[:400]);
            return;
        } elif kind == "__approve__" {
            tool_name = str(data.get("tool", "?"));
            args: any = data.get("args", {});
            parts: list[str] = [];
            if isinstance(args, dict) {
                for pair in args.items() {
                    parts.append(str(pair[0]) + "=" + str(pair[1])[:60]);
                }
            }
            app.appr_tool = tool_name + "(" + (", ".join(parts))[:160] + ")";
            app.phase = "approval";
            app.shell.status.phase = "approval";
            shell_open_approval(app.session, app.shell);
            _push_turn(app, "tool", "? approve " + app.appr_tool);
            app.status_hint = "a accept · r deny";
            app.dirty = True;
        } elif kind == "__done__" {
            _finish_stream(app, str(data.get("answer", "")));
            return;
        }
    }
    if drained {
        app.dirty = True;
    }
}
def _accept_approval(app: LiveShell) {
    if app.phase != "approval" {
        return;
    }
    shell_close_approval(app.session, app.shell);
    app.appr_approved = True;
    if app.appr_event is not None {
        app.appr_event.set();
    }
    _push_turn(app, "tool", "\u2713 approved");
    app.phase = "streaming";
    app.shell.status.phase = "streaming";
    app.status_hint = "streaming \u00b7 esc abort";
    app.dirty = True;
}


def _reject_approval(app: LiveShell) {
    if app.phase == "approval" {
        shell_close_approval(app.session, app.shell);
        app.appr_approved = False;
        if app.appr_event is not None {
            app.appr_event.set();
        }
        _push_turn(app, "tool", "\u2717 denied");
        app.phase = "streaming";
        app.shell.status.phase = "streaming";
        app.status_hint = "streaming \u00b7 esc abort";
        app.dirty = True;
        return;
    }
    if app.phase == "streaming" {
        cancel_active_turn();
        app.status_hint = "aborting\u2026";
        app.dirty = True;
        return;
    }
    app.running = False;
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


"""Slash commands handled locally by the TUI (same set as the line REPL).
Returns a display string; "" when the command produced no output."""
def _run_slash(app: LiveShell, line: str) -> str {
    cwd = os.getcwd();
    if line in ("/exit", "/quit") {
        app.running = False;
        return "";
    }
    if line == "/clear" {
        clear_history();
        app.messages = [];
        app.rev = 0;
        apply_transcript_revision(app.proj, 0, app.messages);
        return "history cleared";
    }
    if line == "/abort" {
        return "turn aborted" if cancel_active_turn() else "no active turn";
    }
    if line == "/sessions" {
        rows = list_sessions(cwd);
        if not rows {
            return "no saved sessions";
        }
        lines: list[str] = ["saved sessions:"];
        for row in rows[:20] {
            lines.append("  " + str(row.get("id", "")) + "  " + str(row.get("name", "")));
        }
        return "\n".join(lines);
    }
    if line.startswith("/resume") {
        arg = line[len("/resume"):].strip();
        sid: str = arg;
        if not sid {
            got = latest_session_id(cwd);
            if got is None {
                return "no saved sessions to resume";
            }
            sid = got;
        }
        rec = get_session_record(cwd, sid);
        if rec is None {
            return "unknown session: " + sid;
        }
        msgs: any = rec.get("messages", []);
        if not isinstance(msgs, list) or not msgs {
            return "session has no transcript: " + sid;
        }
        restore_history(msgs as list);
        # Repaint transcript from restored messages (skip system prompt).
        app.messages = [];
        app.rev = 0;
        apply_transcript_revision(app.proj, 0, app.messages);
        for m in msgs as list {
            if isinstance(m, dict) and str(m.get("role", "")) != "system" {
                _push_turn(app, str(m.get("role", "")), str(m.get("content", "")));
            }
        }
        return "resumed " + sid + " (" + str(len(msgs)) + " messages)";
    }
    if line.startswith("/export") {
        arg = line[len("/export"):].strip();
        path = arg if arg else "jackal-transcript.md";
        hist = get_history();
        has_content = False;
        for m in hist {
            if isinstance(m, dict) and str(m.get("role", "")) != "system" {
                has_content = True;
                break;
            }
        }
        if not has_content {
            return "nothing to export yet";
        }
        if not is_valid_session_id(plugins.session_id) {
            plugins.session_id = new_session_id();
        }
        try {
            meta = save_session(cwd, hist, session_id=plugins.session_id);
        } except Exception as e {
            return "ERROR: could not save transcript: " + str(e);
        }
        if export_session(cwd, str(meta["id"]), path) {
            return "exported to " + path;
        }
        return "ERROR: could not write " + path;
    }
    if line.startswith("/model ") {
        name = line[len("/model "):].strip();
        if name {
            return "model -> " + set_model(name);
        }
        return "usage: /model NAME";
    }
    if line.startswith("/") {
        parts = line[1:].split(None, 1);
        cname = parts[0] if parts else "";
        cargs = parts[1].strip() if len(parts) > 1 else "";
        cmds = list_commands();
        if cname and cname in cmds {
            # Extension commands run OFF the TUI thread (P12): a handler
            # blocking on ui.select must not freeze the mainloop.
            if cname in plugins.commands {
                return _run_ext_command_async(app, cname, cargs);
            }
            return run_command(cname, cargs);
        }
        return "unknown command: " + line + " (/help for list)";
    }
    return "";
}


# ==================== P12: extension ui modal ====================

"""Open the foreground extension-UI modal (one at a time; approval owns the
overlay node while it is up, so UI requests queue behind it)."""
def _ui_open_modal(app: LiveShell, rec: dict) -> bool {
    if app.ui_modal is not None or app.shell.approval is not None {
        return False;
    }
    m: dict = dict(rec);
    m["selected"] = 0;
    m["draft"] = "";
    m["prev_hint"] = app.status_hint;
    app.ui_modal = m;
    shell_open_approval(app.session, app.shell);
    method = str(rec.get("method", ""));
    label = str(rec.get("title", "")) or str(rec.get("message", ""));
    _push_turn(app, "tool", "? [ui] " + method + ": " + label[:80]);
    if method == "select" {
        app.status_hint = "\u2191\u2193 move \u00b7 enter choose \u00b7 esc cancel";
    } elif method == "confirm" {
        app.status_hint = "y confirm \u00b7 n/esc cancel";
    } else {
        app.status_hint = "type \u00b7 enter submit \u00b7 esc cancel";
    }
    app.dirty = True;
    return True;
}


"""Settle the modal: answer via the bridge and restore the prompt state."""
def _ui_settle(app: LiveShell, value: any, use_cancel: bool = False) {
    m: any = app.ui_modal;
    if m is None {
        return;
    }
    app.ui_modal = None;
    shell_close_approval(app.session, app.shell);
    b = plugins.bridge;
    delivered = False;
    if b is not None {
        bb: any = b;
        if use_cancel {
            delivered = cancel_ui(bb, str(m.get("corr", "")), "escape");
        } else {
            delivered = respond_ui(bb, str(m.get("corr", "")), value);
        }
    }
    if not delivered {
        _push_turn(app, "tool", "[ui] request expired");
    } elif not use_cancel {
        _push_turn(app, "tool", "\u2713 answered");
    }
    app.status_hint = str(m.get("prev_hint", app.status_hint));
    app.dirty = True;
}


"""Run an extension command on a daemon worker; completion arrives via
app.cmd_q and is rendered by _tick_cmd. Returns "" (output is async)."""
def _run_ext_command_async(app: LiveShell, name: str, args: str) -> str {
    if app.cmd_q is None {
        app.cmd_q = queue.Queue();
    }
    q = app.cmd_q;

    def worker_main {
        try {
            out = run_command(name, args);
            q.put(("__cmd_done__", {"name": name, "ok": True, "output": str(out)}));
        } except Exception as e {
            q.put(("__cmd_done__", {"name": name, "ok": False, "output": str(e)}));
        }
    }

    threading.Thread(target=worker_main, daemon=True).start();
    _push_turn(app, "tool", "[ext] /" + name + " running\u2026");
    app.dirty = True;
    return "";
}


def _handle_ui_modal_key(app: LiveShell, key: str) {
    m: any = app.ui_modal;
    if m is None {
        return;
    }
    method = str(m.get("method", ""));
    if key == "escape" {
        _ui_settle(app, None, use_cancel=True);
        return;
    }
    if method == "select" {
        options: list = list(m.get("options", []));
        sel = int(m.get("selected", 0));
        moved = False;
        if (key == "up" or key == "k") and len(options) > 0 {
            m["selected"] = (sel - 1) % len(options);
            moved = True;
        } elif (key == "down" or key == "j") and len(options) > 0 {
            m["selected"] = (sel + 1) % len(options);
            moved = True;
        } elif key == "enter" and len(options) > 0 {
            _ui_settle(app, options[min(sel, len(options) - 1)]);
            return;
        }
        if moved {
            app.dirty = True;
        }
        return;
    }
    if method == "confirm" {
        if key == "y" or key == "enter" {
            _ui_settle(app, True);
        } elif key == "n" {
            _ui_settle(app, False);
        }
        return;
    }
    if method == "input" {
        draft = str(m.get("draft", ""));
        if key == "enter" {
            # Empty string stays distinct from Esc-cancel.
            _ui_settle(app, draft);
        } elif key == "backspace" or key == "\x7f" {
            if draft {
                m["draft"] = draft[:-1];
                app.dirty = True;
            }
        } elif len(key) == 1 and key >= " " {
            m["draft"] = draft + key;
            app.dirty = True;
        }
    }
}


"""Poll the bridge interaction queue; open the oldest request as a modal."""
def _tick_ui_modal(app: LiveShell) {
    if app.ui_modal is not None or app.shell.approval is not None {
        return;
    }
    b = plugins.bridge;
    if b is None {
        return;
    }
    polled: any = poll_ui_request(b);
    if polled is not None {
        _ui_open_modal(app, polled);
    }
}


"""Drain extension-command worker completions."""
def _tick_cmd(app: LiveShell) {
    if app.cmd_q is None {
        return;
    }
    drained = False;
    while True {
        try {
            item: any = app.cmd_q.get_nowait();
        } except queue.Empty {
            break;
        }
        drained = True;
        name = str(item[1].get("name", "?"));
        out = str(item[1].get("output", ""));
        ok = item[1].get("ok") is True;
        tag = "[ext] /" + name + " -> ";
        for ln in out.split("\n")[:8] {
            _push_turn(app, "tool", tag + ln[:160]);
            tag = "      ";
        }
        if not ok {
            _push_turn(app, "tool", "! [ext] /" + name + " failed");
        }
    }
    if drained {
        app.dirty = True;
    }
}


"""Unified per-frame tick: UI modals + command workers + stream events."""
def _tick_app(app: LiveShell) {
    _tick_cmd(app);
    _tick_ui_modal(app);
    if app.phase == "streaming" {
        _tick_stream(app);
    } elif app.phase == "approval" {
        # Keep the status meter alive while the modal sits.
        app.spin_i += 1;
        if app.spin_i % 4 == 0 {
            app.dirty = True;
        }
    }
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
    # Extension-UI modal first: it shares the overlay node with approvals,
    # so the generic approval branch would otherwise swallow every key.
    if app.ui_modal is not None {
        _handle_ui_modal_key(app, key);
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
        if app.phase == "streaming" {
            cancel_active_turn();
            app.status_hint = "aborting…";
            app.dirty = True;
            return;
        }
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
        if text.startswith("/") {
            reply = _run_slash(app, text);
            if reply {
                _push_turn(app, "tool", reply);
            }
            app.dirty = True;
            return;
        }
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


def run_tui() {
    # Extensions load per .jackal/extensions.json (parallel sidecar when declared).
    try {
        session_boot(interactive_ui=True);
    } except Exception {
    }
    app = create_live_shell();
    app.cmd_q = queue.Queue();
    app.term.start();
    app.term.set_title("Jackal — " + model);
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
            _tick_app(app);
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
        print("jackal tui needs a real TTY.");
        raise SystemExit(1);
    }
    run_tui();
}
