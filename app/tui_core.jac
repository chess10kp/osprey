"""Transcript, layout, and formatting helpers for LiveShell."""
import from tui_state { LiveShell, SPINNER }
import from agent.modes { is_read_only_mode }
import from ui.transcript {
    TranscriptMessage, apply_transcript_revision, measure_message_height, set_follow_tail,
}
import from ui.layout { LayoutSpec, fill_axis, fixed_axis }
import from ui.screen { configure_main_shell_layout }
import from ui.renderer { set_node_contract }
import from ui.width { display_width, truncate_text }

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
    # status/prompt legacy heights), then this shell's parity override:
    # hide the framework header and keep the prompt at three rows.
    configure_main_shell_layout(app.renderer.layout, app.shell);
    set_node_contract(
        app.renderer,
        app.shell.header,
        LayoutSpec(width=fill_axis(), height=fixed_axis(0)),
    );
    set_node_contract(
        app.renderer,
        app.shell.prompt,
        LayoutSpec(width=fill_axis(), height=fixed_axis(3)),
    );
}


"""Status-line badge for the active dev mode (empty for normal)."""
def _mode_badge(mode: str) -> str {
    if mode == "normal" {
        return "";
    }
    if mode == "auto-accept" {
        return " AUTO ";
    }
    if mode == "yolo" {
        return " YOLO ";
    }
    if mode == "plan" {
        return " PLAN ";
    }
    if mode == "ask" {
        return " ASK ";
    }
    return " " + mode.upper() + " ";
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
    badge = _mode_badge(app.mode);
    left = "";
    if badge {
        # Read-only modes get the loudest marker; yolo/auto stay visible
        # but quieter (no trailing !).
        if is_read_only_mode(app.mode) {
            left = badge + "! ";
        } else {
            left = badge + " ";
        }
    }
    left = left + phase + "  " + _meter(app.progress_value, 14);
    right = app.status_hint;
    gap = app.columns - display_width(left) - display_width(right) - 2;
    if gap < 1 {
        return truncate_text(left + "  " + right, app.columns, ellipsis="…");
    }
    return left + (" " * gap) + right;
}


"""Prompt-box draft prefix — read-only modes get an unmistakable marker."""
def _prompt_prefix(mode: str) -> str {
    if mode == "plan" {
        return "[plan] ❯ ";
    }
    if mode == "ask" {
        return "[ask] ❯ ";
    }
    return "❯ ";
}


def _prompt_lines(app: LiveShell) -> list[str] {
    draft = app.shell.prompt.draft;
    w = app.columns;
    top = "╭" + _rule(max(0, w - 2), "─") + "╮";
    body_inner = _prompt_prefix(app.mode) + draft;
    body = "│" + _pad_to(body_inner, max(0, w - 2)) + "│";
    if app.phase == "streaming" {
        hint = "streaming — wait for jackal";
    } elif app.shell.approval is not None {
        hint = "modal — a accept · r reject";
    } else {
        hint = "enter send · ↑↓ history · ctrl+u clear";
    }
    if is_read_only_mode(app.mode) and app.phase != "streaming" and app.shell.approval is None {
        hint = "READ-ONLY · shift+tab to cycle out";
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
