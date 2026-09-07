"""Streaming worker and approval lifecycle."""
import threading;
import queue;
import from tui_state { LiveShell }
import from tui_core { _push_turn, _rewrite_turn }
import from agent.session { run_turn, cancel_active_turn }
import from agent.modes {
    requires_approval, is_read_only_mode, read_only_mode_block_reason,
}
import from ui.screen {
    shell_open_approval, shell_close_approval, shell_resize,
}
import from ui.progress_bar { SetProgress }
import from ui.renderer { create_renderer }

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
def _begin_assistant_reply(app: LiveShell, user_text: str, model_text: str = "") {
    # Transcript shows the RAW user line (mirrors the legacy shells);
    # model_text — when different — is the context-expanded payload
    # (@file blocks / !cmd output) actually sent downstream.
    payload = model_text if model_text else user_text;
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

    # Tool approver: auto-allow per the ACTIVE dev mode (Shift+Tab cycle);
    # destructive ones raise the modal and block the WORKER thread on an
    # Event until the UI resolves it.
    def approve(name: str, args: dict) -> any {
        cmd = "";
        if isinstance(args, dict) {
            cmd = str(args.get("cmd", ""));
        }
        policy = requires_approval(app.mode, name, cmd);
        if policy == "auto" {
            return True;
        }
        if policy == "blocked" {
            # react_loop wraps a non-True verdict as an ERROR tool result and
            # relays it through the event queue — the transcript gets the
            # ERROR row without this worker thread touching UI state.
            if is_read_only_mode(app.mode) {
                return read_only_mode_block_reason(name, app.mode);
            }
            return "blocked in " + app.mode + " mode";
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
            answer = run_turn(payload, collector, approve=approve);
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
