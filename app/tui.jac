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
    run_extension_shortcut,
    list_extension_shortcuts,
    plugins,
    new_session_id,
    model_preferences,
}
import from agent.llm {
    PROVIDER_ROUTES,
    credential_error,
    provider_for,
}
import from agent.modes { requires_approval }
import from core.edit { compute_unified_diff }
import from agent.plugin_bridge {
    poll_ui_request,
    respond_ui,
    cancel_ui,
}
import from agent.sessions {
    list_sessions,
    get_session_record,
    export_session,
    save_session,
    is_valid_session_id,
}
import from agent.tasks {
    load_tasks,
    format_tasks_list,
    task_counts,
}
import from agent.checkpoints {
    create_checkpoint,
    list_checkpoints,
    load_checkpoint,
    restore_checkpoint_files,
    format_checkpoint_overlay_row,
}
import os;

import from ui.runtime {
    UiSession,
    create_session,
    dispose_session,
}

import from ui.model {
    UiNode,
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
    measure_message_height,
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
    UiNode,
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

# Built-in slash commands handled by _run_slash locally (name without the
# leading "/" -> short description for the autocomplete popup).
glob SLASH_BUILTINS: dict[str, str] = {
    "exit": "quit jackal",
    "quit": "quit jackal",
    "clear": "clear conversation history",
    "abort": "abort the active turn",
    "sessions": "list saved sessions",
    "resume": "resume a saved session",
    "export": "export transcript to markdown",
    "model": "show or set the model",
    "commands": "list extension commands",
    "shortcuts": "list extension shortcuts",
    "tasks": "list project tasks",
    "checkpoint": "create a checkpoint (/checkpoint NAME)",
    "checkpoints": "browse and restore checkpoints",
};


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
        appr_tool_name: str = "",
        appr_args: any = None,
        ui_modal: any = None,
        picker: any = None,
        cmd_q: any = None,
        slash_sel: int = 0,
        slash_dismissed: str = "";
}

# Picker rows come from agent.llm PROVIDER_ROUTES (one header per provider
# followed by its advertised models) plus each provider's last-used model
# from agent.session model_preferences(). Header rows carry the sentinel id
# __header__ and are skipped on enter.
def _model_picker_entries() -> dict {
    rows: list[str] = [];
    ids: list[str] = [];
    prefs: dict = {};
    try {
        prefs = dict(model_preferences());
    } except Exception {
        prefs = {};
    }
    for prov in PROVIDER_ROUTES {
        route = PROVIDER_ROUTES[prov];
        meta: any = route if isinstance(route, dict) else {};
        desc = str(meta.get("description", "") or "");
        header = "── " + str(prov);
        if desc {
            header += " — " + desc;
        }
        rows.append(header + " ──");
        ids.append("__header__");
        for m in (meta.get("models", []) or []) {
            mname = str(m);
            rows.append("  " + mname);
            ids.append(mname);
        }
        last = str(prefs.get(str(prov), "") or "");
        if last {
            rows.append("  " + last + "  · last");
            ids.append(last);
        }
    }
    return {"rows": rows, "ids": ids};
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


"""Total wrapped-line height of the transcript (local copy of the private
projection helper — keeps this file free of underscore imports)."""
def _transcript_total_height(app: LiveShell) -> int {
    total = 0;
    for message in app.proj.messages {
        total += measure_message_height(
            app.proj,
            message,
            app.proj.viewport_width,
        );
    }
    return total;
}


"""Scroll the transcript viewport by delta lines (negative = up).

Leaves follow_tail on the first upward scroll so streaming chunks append
offscreen while the view is frozen; re-enters tail automatically once the
bottom is reached (End behaves the same via set_follow_tail(True))."""
def _scroll_transcript(app: LiveShell, delta: int) {
    proj = app.proj;
    if delta == 0 {
        return;
    }
    vh = max(1, proj.viewport_height);
    if delta > 0 and proj.view.follow_tail {
        return;  # already pinned to newest content
    }
    if delta < 0 and proj.view.follow_tail {
        set_follow_tail(proj, False);
    }
    total = _transcript_total_height(app);
    max_off = max(0, total - vh);
    off = min(max(0, proj.view.scroll_offset + delta), max_off);
    proj.view.scroll_offset = off;
    if off >= max_off and not proj.view.follow_tail {
        set_follow_tail(proj, True);
        app.status_hint = "enter · ↑↓ history · esc quit";
    } else {
        app.status_hint = (
            "scrollback " + str(off) + "/" + str(max_off) + " · end/pgdn = live"
        );
    }
    app.dirty = True;
}


"""Unified-diff preview lines for a pending write_file/edit_file approval.
Capped at 20 diff lines with a trailing truncation marker; returns [] when
no old/new text pair can be assembled (missing args, unreadable baseline)."""
def _approval_diff_preview(name: str, args: dict[str, any]) -> list[str] {
    old_text = "";
    new_text = "";
    if name == "edit_file" {
        old_text = str(args.get("old_text", ""));
        new_text = str(args.get("new_text", ""));
    } elif name == "write_file" {
        new_text = str(args.get("content", ""));
        path = str(args.get("path", ""));
        if path {
            full = path if os.path.isabs(path) else os.path.join(os.getcwd(), path);
            # Baseline is read from disk at render time (preview only);
            # a missing file means every line is an addition.
            if os.path.isfile(full) {
                try {
                    fh = open(full);
                    old_text = fh.read();
                    fh.close();
                } except Exception {
                    return [];
                }
            }
        } else {
            return [];
        }
    } else {
        return [];
    }
    diff = compute_unified_diff(old_text, new_text);
    if not diff or diff.startswith("ERROR") {
        return [];
    }
    raw: list[str] = diff.split("\n");
    cap = 20;
    shown: list[str] = raw[:cap];
    out: list[str] = ["diff:"];
    for ln in shown {
        prefix = " ";
        if ln.startswith("+") or ln.startswith("-") or ln.startswith("@") {
            prefix = "";
        }
        out.append(prefix + ln);
    }
    more = len(raw) - cap;
    if more > 0 {
        out.append("… " + str(more) + " more lines");
    }
    return out;
}


"""Approval overlay body — REAL pending-approval data: tool name plus cmd
(run_command), target path and old/new char counts (write_file/edit_file)
or generic key=value pairs, then a capped unified-diff preview."""
def _approval_lines(app: LiveShell) -> list[str] {
    inner = 46;
    head = "TOOL APPROVAL · " + app.appr_tool_name;
    body: list[str] = [];
    args: any = app.appr_args;
    if isinstance(args, dict) {
        if app.appr_tool_name == "run_command" {
            body.append("$ " + str(args.get("cmd", "")));
            timeout_secs = str(args.get("timeout_secs", ""));
            if timeout_secs {
                body.append("timeout " + timeout_secs + "s");
            }
        } elif app.appr_tool_name == "write_file" {
            body.append(str(args.get("path", "")));
            body.append("+ " + str(len(str(args.get("content", "")))) + " chars");
        } elif app.appr_tool_name == "edit_file" {
            body.append(str(args.get("path", "")));
            body.append(
                "- " + str(len(str(args.get("old_text", ""))))
                + " / + " + str(len(str(args.get("new_text", "")))) + " chars"
            );
        } else {
            parts: list[str] = [];
            for pair in args.items() {
                parts.append(str(pair[0]) + "=" + str(pair[1])[:40]);
            }
            body.append((", ".join(parts))[:inner - 6]);
        }
        body.extend(_approval_diff_preview(app.appr_tool_name, args));
    }
    if not body {
        body.append("(no details available)");
    }
    lines: list[str] = [
        "╭" + _rule(inner, "─") + "╮",
        "│" + _pad_to("  " + head, inner) + "│",
        "│" + _pad_to("", inner) + "│",
    ];
    for ln in body {
        lines.append("│" + _pad_to("  " + ln, inner) + "│");
    }
    lines.append("│" + _pad_to("", inner) + "│");
    lines.append("│" + _pad_to("  [a] Accept    [r] Reject    [esc]", inner) + "│");
    lines.append("╰" + _rule(inner, "─") + "╯");
    return lines;
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


"""Generic list-picker overlay body (model chooser / resume chooser).
Mirrors the extension-modal box styling; select mode shows rows with a
">" cursor, input mode shows an editable draft line."""
def _picker_lines(app: LiveShell) -> list[str] {
    p: any = app.picker;
    inner = 46;
    head = "? " + str(p.get("title", ""));
    body: list[str] = [];
    if str(p.get("mode", "select")) == "input" {
        draft = str(p.get("draft", ""));
        shown = draft if draft else "(type a model id)";
        body.append("  > " + shown[:inner - 8] + "▌");
    } else {
        options: list = list(p.get("options", []));
        sel = int(p.get("selected", 0));
        i = 0;
        for opt in options[:8] {
            mark = ">" if i == sel else " ";
            body.append(mark + " " + str(opt)[:inner - 6]);
            i += 1;
        }
        more = len(options) - 8;
        if more > 0 {
            body.append("… " + str(more) + " more");
        }
    }
    body.append("");
    if str(p.get("mode", "select")) == "input" {
        body.append("  type id · [enter] submit   [esc] cancel");
    } else {
        body.append("  [↑↓] move   [enter] choose   [esc] cancel");
    }
    lines: list[str] = [
        "╭" + _rule(inner, "─") + "╮",
        "│" + _pad_to("  " + head, inner) + "│",
    ];
    for ln in body {
        lines.append("│" + _pad_to("  " + ln, inner) + "│");
    }
    lines.append("╰" + _rule(inner, "─") + "╯");
    return lines;
}


"""Open a generic list-picker on the shared overlay node (one at a time).
rows are display labels; ids map 1:1 onto action payloads. When
extra_last_input is set, a trailing "type name…" row flips the picker into
free-text input mode on enter."""
def _open_picker(
    app: LiveShell,
    title: str,
    rows: list[str],
    ids: list[str],
    extra_last_input: bool = False,
) -> bool {
    if app.picker is not None or app.ui_modal is not None or app.shell.approval is not None {
        return False;
    }
    options = list(rows);
    full_ids = list(ids);
    if extra_last_input {
        options.append("type name…");
        full_ids.append("__type__");
    }
    if not options {
        return False;
    }
    app.picker = {
        "title": title,
        "options": options,
        "ids": full_ids,
        "selected": 0,
        "mode": "select",
        "draft": "",
        "prev_hint": app.status_hint,
    };
    shell_open_approval(app.session, app.shell);
    app.status_hint = "↑↓ move · enter choose · esc cancel";
    app.dirty = True;
    return True;
}


"""Dismiss the picker and restore the pre-open status hint."""
def _close_picker(app: LiveShell) {
    p: any = app.picker;
    app.picker = None;
    shell_close_approval(app.session, app.shell);
    if p is not None {
        app.status_hint = str(p.get("prev_hint", app.status_hint));
    }
    app.dirty = True;
}


"""Model picker: provider-grouped rows from PROVIDER_ROUTES (headers,
advertised models, per-provider "· last" entries), the active model
injected when missing, plus a free-text fallback row; cursor starts on
the active model."""
def _open_model_picker(app: LiveShell) -> str {
    entries = _model_picker_entries();
    choices: list[str] = list(entries["rows"]);
    pick_ids: list[str] = list(entries["ids"]);
    if model not in pick_ids {
        choices.insert(0, model + "  · current");
        pick_ids.insert(0, model);
    }
    sel = 0;
    i = 0;
    for c in pick_ids {
        if c == model {
            sel = i;
            break;
        }
        i += 1;
    }
    opened = _open_picker(app, "MODEL", choices, pick_ids, extra_last_input=True);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    p: any = app.picker;
    if p is not None {
        p["selected"] = sel;
    }
    return "";
}


def _handle_picker_key(app: LiveShell, key: str) {
    p: any = app.picker;
    if p is None {
        return;
    }
    title = str(p.get("title", ""));
    if key == "escape" {
        _close_picker(app);
        return;
    }
    if str(p.get("mode", "select")) == "input" {
        draft = str(p.get("draft", ""));
        if key == "enter" {
            name = draft.strip();
            _close_picker(app);
            if name {
                _push_turn(app, "tool", "model -> " + set_model(name));
                app.dirty = True;
            }
        } elif key == "backspace" or key == "\x7f" {
            if draft {
                p["draft"] = draft[:-1];
                app.dirty = True;
            }
        } elif len(key) == 1 and key >= " " {
            p["draft"] = draft + key;
            app.dirty = True;
        }
        return;
    }
    options: list = list(p.get("options", []));
    ids: list = list(p.get("ids", []));
    sel = int(p.get("selected", 0));
    if (key == "up" or key == "k") and len(options) > 0 {
        p["selected"] = (sel - 1) % len(options);
        app.dirty = True;
    } elif (key == "down" or key == "j") and len(options) > 0 {
        p["selected"] = (sel + 1) % len(options);
        app.dirty = True;
    } elif key == "enter" and len(options) > 0 {
        idx = min(sel, len(options) - 1);
        chosen_id = str(ids[idx]) if idx < len(ids) else "";
        chosen = str(options[idx]);
        if chosen_id == "__type__" {
            p["mode"] = "input";
            p["draft"] = "";
            app.status_hint = "type model id · enter submit · esc cancel";
            app.dirty = True;
            return;
        }
        if chosen_id == "__header__" {
            # Header/divider/summary rows are separators, not choices
            # (provider headers in MODEL, board furniture in TASKS).
            app.dirty = True;
            return;
        }
        _close_picker(app);
        if title == "MODEL" {
            mname = chosen_id or chosen;
            cerr = credential_error(mname);
            if cerr {
                # Missing credentials: surface which env var to set instead of
                # switching (same tool-row path as /command results).
                _push_turn(app, "tool", cerr);
            } else {
                _push_turn(app, "tool", "model -> " + mname);
                set_model(mname);
            }
        } elif title == "RESUME SESSION" {
            reply = _resume_session(app, chosen_id);
            if reply {
                _push_turn(app, "tool", reply);
            }
        } elif title == "TASKS" {
            # Read-only overlay: echo the full rendered board into the
            # transcript so long lists survive past the 8-row overlay cap.
            _push_turn(app, "tool", format_tasks_list(load_tasks(os.getcwd())));
        } elif title == "CHECKPOINTS" {
            reply = _restore_checkpoint(app, chosen_id);
            if reply {
                _push_turn(app, "tool", reply);
            }
        }
        app.dirty = True;
    }
}


"""Resume-picker rows from list_sessions(cwd): label "id  name", payload id."""
def _open_resume_picker(app: LiveShell) -> str {
    rows = list_sessions(os.getcwd());
    if not rows {
        return "no saved sessions";
    }
    labels: list[str] = [];
    ids: list[str] = [];
    for row in rows[:20] {
        sid = str(row.get("id", ""));
        sname = str(row.get("name", ""));
        labels.append(sid[:18] + "  " + sname[:38]);
        ids.append(sid);
    }
    opened = _open_picker(app, "RESUME SESSION", labels, ids);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}


"""TASKS picker rows: a completion-meter summary line, then the rendered
board from format_tasks_list (counts header, divider rule, one row per
task). Row ids: "__header__" for non-selectable lines, the task index as
a string otherwise. Pure over cwd — replicated in tui_overlays.test.jac
(tui.jac cannot be imported headless; keep in sync with the replica)."""
def _task_picker_entries(cwd: str) -> dict {
    tasks = load_tasks(cwd);
    if not tasks {
        return {"rows": ["No tasks yet."], "ids": ["__header__"]};
    }
    counts = task_counts(tasks);
    total: int = int(counts["pending"]) + int(counts["in_progress"]) + int(counts["completed"]);
    ratio: float = float(counts["completed"]) / float(total) if total else 0.0;
    rows: list[str] = [
        str(total) + " tasks  " + _meter(ratio, 14) + "  "
        + str(counts["completed"]) + "/" + str(total) + " done"
    ];
    ids: list[str] = ["__header__"];
    idx = 0;
    for ln in format_tasks_list(tasks).split("\n") {
        rows.append(ln);
        # First two board lines are the counts header and divider rule;
        # everything after maps back onto its task index for enter.
        if idx >= 2 {
            ids.append(str(idx - 2));
        } else {
            ids.append("__header__");
        }
        idx += 1;
    }
    return {"rows": rows, "ids": ids};
}


"""CHECKPOINTS picker rows via list_checkpoints (newest first), one
format_checkpoint_overlay_row line per checkpoint; ids are names. Pure
over cwd — replicated in tui_overlays.test.jac (keep in sync)."""
def _checkpoint_picker_entries(cwd: str) -> dict {
    items = list_checkpoints(cwd);
    rows: list[str] = [];
    ids: list[str] = [];
    for item in items[:20] {
        rows.append(format_checkpoint_overlay_row(item));
        ids.append(str(item.get("name", "")));
    }
    return {"rows": rows, "ids": ids};
}


"""Open the read-only tasks overlay; enter on a task echoes the full
rendered board into the transcript."""
def _open_tasks_picker(app: LiveShell) -> str {
    entries = _task_picker_entries(os.getcwd());
    opened = _open_picker(app, "TASKS", entries["rows"], entries["ids"]);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}


"""Open the checkpoints overlay for browse/restore."""
def _open_checkpoints_picker(app: LiveShell) -> str {
    entries = _checkpoint_picker_entries(os.getcwd());
    if not entries["rows"] {
        return "no checkpoints yet (/checkpoint NAME to create one)";
    }
    opened = _open_picker(app, "CHECKPOINTS", entries["rows"], entries["ids"]);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}


"""Snapshot the current conversation plus working-tree changes into a new
named checkpoint (/checkpoint NAME). Provider/model come from the active
session model via provider_for."""
def _create_checkpoint_now(app: LiveShell, name: str) -> str {
    cwd = os.getcwd();
    hist = get_history();
    try {
        meta = create_checkpoint(cwd, hist, provider_for(model), model, name=name);
    } except Exception as e {
        return "ERROR: checkpoint failed: " + str(e);
    }
    files_changed: any = meta.get("filesChanged", []);
    n_files = len(files_changed) if isinstance(files_changed, list) else 0;
    app.dirty = True;
    return (
        "checkpoint '" + str(meta.get("name", name)) + "' saved ("
        + str(len(hist)) + " msgs, " + str(n_files) + " files)"
    );
}


"""Restore a checkpoint: write its file snapshots back under cwd, swap the
agent history for the stored conversation, and repaint the transcript.

Known gaps (honest scope of this pass):
- The on-disk session record (.jackal/sessions) is NOT rewritten; it still
  reflects pre-restore turns until the next save/export.
- Transcript rows are rebuilt from raw conversation roles only, so tool-
  call formatting is approximated (same tradeoff as /resume)."""
def _restore_checkpoint(app: LiveShell, name: str) -> str {
    cwd = os.getcwd();
    try {
        payload: any = load_checkpoint(cwd, name);
    } except Exception as e {
        return "ERROR: cannot load checkpoint '" + name + "': " + str(e);
    }
    conv: any = payload.get("conversation") if isinstance(payload, dict) else None;
    msgs: any = conv.get("messages", []) if isinstance(conv, dict) else [];
    if not isinstance(msgs, list) {
        msgs = [];
    }
    note = "";
    files: any = payload.get("fileSnapshots", {}) if isinstance(payload, dict) else {};
    if isinstance(files, dict) and files {
        try {
            restore_checkpoint_files(cwd, files);
            note = ", " + str(len(files)) + " files restored";
        } except Exception as e {
            note = ", FILE RESTORE FAILED: " + str(e).split("\n")[0][:80];
        }
    }
    # Swap agent memory and repaint from the snapshot conversation.
    restore_history(msgs as list);
    app.messages = [];
    app.rev = 0;
    apply_transcript_revision(app.proj, 0, app.messages);
    for m in msgs as list {
        if isinstance(m, dict) and str(m.get("role", "")) != "system" {
            _push_turn(app, str(m.get("role", "")), str(m.get("content", "")));
        }
    }
    app.dirty = True;
    return "checkpoint '" + name + "' restored (" + str(len(msgs)) + " msgs" + note + ")";
}


"""Paint lines into the shared overlay node (picker/modal/approval owner).
The caller has already decided ownership; this just guards the optional node."""
def _paint_overlay(app: LiveShell, lines: list[str]) {
    ov: UiNode | None = app.shell.approval;
    if ov is None {
        return;
    }
    set_node_contract(
        app.renderer,
        ov,
        LayoutSpec(
            width=fixed_axis(48),
            height=fixed_axis(len(lines)),
            overlay_anchor=OverlayAnchor.CENTER,
        ),
    );
    set_node_content(app.renderer, ov, lines);
    mark_semantic_dirty(app.renderer, ov);
    mark_layout_dirty(app.renderer, ov);
}


# ==================== slash-command autocomplete ====================

"""Slash-command candidates for the typed prefix: built-ins plus extension
commands (list_commands()), deduped, alphabetical, capped at 6. Each entry
is [name_with_slash, description]. Empty when the draft is not a bare
command word."""
def _slash_candidates(draft: str) -> list[list[str]] {
    text = draft.strip();
    if not text.startswith("/") or " " in text {
        return [];
    }
    token: str = text;
    descs: dict[str, str] = {};
    for bname in SLASH_BUILTINS {
        full = "/" + str(bname);
        descs[full] = str(SLASH_BUILTINS[bname]);
    }
    try {
        cmds = list_commands();
    } except Exception {
        cmds = {};
    }
    if isinstance(cmds, dict) {
        for cname in cmds {
            full = "/" + str(cname);
            if full in descs {
                continue;  # built-in shadows same-named extension command
            }
            meta: dict = cmds[cname] if isinstance(cmds[cname], dict) else {};
            descs[full] = str(meta.get("description", "") or "");
        }
    }
    out: list[list[str]] = [];
    for name in sorted(descs) {
        if name.startswith(token) {
            out.append([name, descs[name]]);
            if len(out) >= 6 {
                break;
            }
        }
    }
    return out;
}


"""Popup visibility + candidates in one shot: hidden while any modal,
picker or approval owns the screen, when the draft is not a bare "/word",
or when the user dismissed this exact draft with esc. Returns the match
list or None."""
def _slash_popup_state(app: LiveShell) -> list[list[str]] | None {
    if app.picker is not None or app.ui_modal is not None or app.shell.approval is not None {
        return None;
    }
    text = app.shell.prompt.draft.strip();
    if not text.startswith("/") or " " in text {
        return None;
    }
    if text == app.slash_dismissed {
        return None;
    }
    matches = _slash_candidates(text);
    if not matches {
        return None;
    }
    return matches;
}


""">-cursor rows for the popup (selected entry marked, description
truncated to the terminal width). Selection clamps into range so stale
indices from earlier filters never crash the paint."""
def _slash_popup_rows(app: LiveShell, matches: list[list[str]]) -> list[str] {
    max_w = max(10, app.columns - 2);
    sel = int(app.slash_sel);
    if sel >= len(matches) {
        sel = len(matches) - 1;
    }
    if sel < 0 {
        sel = 0;
    }
    rows: list[str] = [];
    i = 0;
    for m in matches {
        mark = ">" if i == sel else " ";
        label = str(m[0]);
        desc = str(m[1]);
        if desc {
            label += " — " + desc;
        }
        rows.append(truncate_text(mark + " " + label, max_w, ellipsis="…"));
        i += 1;
    }
    return rows;
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

    # Slash autocomplete: extra rows painted ABOVE the prompt box inside the
    # prompt node; its fixed contract grows/shrinks with the popup each frame.
    popup: list[list[str]] | None = _slash_popup_state(app);
    popup_rows: list[str] = [];
    if popup is not None {
        popup_rows = _slash_popup_rows(app, popup);
    }
    set_node_contract(
        app.renderer,
        app.shell.prompt,
        LayoutSpec(
            width=fill_axis(),
            height=fixed_axis(3 + len(popup_rows)),
        ),
    );

    # Shared overlay node: local pickers own it first, then extension modals,
    # then tool approvals.
    overlay: list[str] | None = None;
    if app.picker is not None {
        overlay = _picker_lines(app);
    } elif app.ui_modal is not None {
        overlay = _ui_modal_lines(app);
    } elif app.shell.approval is not None {
        overlay = _approval_lines(app);
    }
    if overlay is not None {
        _paint_overlay(app, overlay);
    }

    set_node_content(app.renderer, app.shell.header, header);
    set_node_content(app.renderer, app.shell.transcript, lines);
    set_node_content(app.renderer, app.shell.status, [status]);
    set_node_content(app.renderer, app.shell.prompt, popup_rows + prompt_lines);
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
    request_cursor(
        app.renderer,
        app.shell.prompt,
        row_offset=1 + len(popup_rows),
        col_offset=cursor_col,
    );
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
            app.appr_tool_name = tool_name;
            app.appr_args = args if isinstance(args, dict) else {};
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


"""Restore a saved session by id and repaint the transcript from it.
Shared by /resume NAME and the resume picker's enter action."""
def _resume_session(app: LiveShell, sid: str) -> str {
    cwd = os.getcwd();
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
    app.dirty = True;
    return "resumed " + sid + " (" + str(len(msgs)) + " messages)";
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
        if not arg {
            # No argument: open an interactive session picker instead of
            # silently resuming the latest session.
            return _open_resume_picker(app);
        }
        return _resume_session(app, arg);
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
    if line == "/shortcuts" {
        scs = list_extension_shortcuts();
        if not scs {
            return "no extension shortcuts registered";
        }
        lines: list[str] = ["extension shortcuts:"];
        for key in scs {
            meta: dict = scs[key] if isinstance(scs[key], dict) else {};
            lines.append("  " + str(key) + " — " + str(meta.get("description", "") or "") + " (" + str(meta.get("extension_id", "") or "") + ")");
        }
        return "\n".join(lines);
    }
    if line == "/commands" {
        cmds = list_commands();
        if not cmds {
            return "no extension commands";
        }
        lines: list[str] = ["extension commands:"];
        for cname in cmds {
            meta: dict = cmds[cname] if isinstance(cmds[cname], dict) else {};
            lines.append("  /" + str(cname) + " — " + str(meta.get("description", "") or ""));
        }
        return "\n".join(lines);
    }
    if line == "/model" or line.startswith("/model ") {
        name = line[len("/model"):].strip();
        if not name {
            # No argument: interactive picker (curated list + free-text row).
            return _open_model_picker(app);
        }
        return "model -> " + set_model(name);
    }
    if line == "/tasks" {
        return _open_tasks_picker(app);
    }
    if line == "/checkpoints" {
        return _open_checkpoints_picker(app);
    }
    if line == "/checkpoint" or line.startswith("/checkpoint ") {
        arg = line[len("/checkpoint"):].strip();
        if not arg {
            # No argument: browse/restore instead of creating a nameless one.
            return _open_checkpoints_picker(app);
        }
        return _create_checkpoint_now(app, arg);
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
        return "unknown command: " + line + " (/commands /shortcuts for lists)";
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
    if app.picker is not None {
        _handle_picker_key(app, key);
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
    # Extension keyboard shortcuts (pi.registerShortcut): modifier-combo keys
    # registered by loaded extensions shadow built-in navigation, matching Pi
    # global-binding semantics. ctrl+c / modals / approvals keep precedence.
    scs = list_extension_shortcuts();
    if key in scs {
        meta: dict = scs[key];
        desc = str(meta.get("description", "") or "");
        app.status_hint = "shortcut " + key + (" — " + desc if desc else "");
        reply = run_extension_shortcut(key);
        if reply {
            _push_turn(app, "tool", reply);
        }
        app.dirty = True;
        return;
    }
    # Slash-command autocomplete popup: owns up/down/tab/enter/escape while
    # visible; printable chars and backspace fall through to editing below —
    # the paint-time filter picks up the new draft automatically. j/k stay
    # out on purpose: they must keep inserting text for live filtering.
    popup: list[list[str]] | None = _slash_popup_state(app);
    if popup is not None {
        count = len(popup);
        if key == "up" {
            app.slash_sel = (int(app.slash_sel) - 1 + count) % count;
            app.dirty = True;
            return;
        }
        if key == "down" {
            app.slash_sel = (int(app.slash_sel) + 1) % count;
            app.dirty = True;
            return;
        }
        if key == "tab" or key == "enter" {
            idx = int(app.slash_sel);
            if idx >= count {
                idx = count - 1;
            }
            if idx < 0 {
                idx = 0;
            }
            chosen = str(popup[idx][0]);
            app.shell.prompt.draft = chosen;
            app.shell.prompt.caret = len(chosen);
            app.shell.prompt.history_index = -1;
            # Dismiss at the completed draft: enter must submit on the next
            # press, not re-complete.
            app.slash_dismissed = chosen;
            app.dirty = True;
            return;
        }
        if key == "escape" {
            # First esc closes the popup without touching the draft; the
            # second one (popup now hidden) keeps the existing behavior.
            app.slash_dismissed = app.shell.prompt.draft.strip();
            app.dirty = True;
            return;
        }
    }
    if key == "page_up" {
        # Scrollback works during streaming too: the frozen view just means
        # new chunks append offscreen until tail is re-entered.
        _scroll_transcript(app, -(max(1, app.proj.viewport_height) - 1));
        return;
    }
    if key == "page_down" {
        _scroll_transcript(app, max(1, app.proj.viewport_height) - 1);
        return;
    }
    if key == "home" {
        set_follow_tail(app.proj, False);
        app.proj.view.scroll_offset = 0;
        app.status_hint = "scrollback top · end/pgdn = live";
        app.dirty = True;
        return;
    }
    if key == "end" {
        set_follow_tail(app.proj, True);
        app.status_hint = "enter · ↑↓ history · esc quit";
        app.dirty = True;
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
            if app.picker is not None {
                # Picker input mode owns typed characters while open.
                for ch in event.text {
                    _handle_picker_key(app, ch);
                }
                continue;
            }
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
            if app.shell.approval is None and app.phase != "streaming" and app.picker is None {
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
