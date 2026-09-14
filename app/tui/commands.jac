"""Slash commands and extension UI handling."""
import os;
import threading;
import queue;
import from tui.state { LiveShell }
import from tui.core { _push_turn }
import from tui.picker_actions {
    _open_login_picker, _open_model_picker, _open_resume_picker,
    _open_tasks_picker, _open_checkpoints_picker, _create_checkpoint_now,
    _open_skills_picker,
}
import from tui.context { _open_explorer_picker }
import from tui.mcp { _open_mcp_picker }
import from tui.runtime { _begin_assistant_reply }
import from agent.session {
    clear_history, get_history, restore_history, list_commands,
    run_command, list_extension_shortcuts, run_extension_shortcut, plugins,
    new_session_id, set_model, cancel_active_turn,
}
import from agent.sessions {
    list_sessions, get_session_record, export_session, save_session,
    is_valid_session_id,
}
import from agent.skills { load_jackal_skills, expand_skill_command }
import from agent.plugin_bridge { poll_ui_request, respond_ui, cancel_ui }
import from ui.screen { shell_open_approval, shell_close_approval }
import from ui.transcript { apply_transcript_revision }

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
    if line == "/login" or line.startswith("/login ") {
        arg = line[len("/login"):].strip();
        return _open_login_picker(app, arg);
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
    if line == "/explorer" {
        return _open_explorer_picker(app);
    }
    if line == "/mcp" {
        return _open_mcp_picker(app);
    }
    if line == "/skills" {
        return _open_skills_picker(app);
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
    if line.startswith("/skill:") {
        # Inline skill expansion: the transcript keeps the typed command;
        # the model receives the <skill> block with args appended.
        try {
            catalog: dict = load_jackal_skills();
        } except Exception as e {
            return "ERROR: failed to load skills: " + str(e);
        }
        expanded = expand_skill_command(line, catalog["skills"]);
        if expanded == line {
            unknown = line[7:].split(" ", 1)[0];
            return "unknown skill: " + unknown + " (/skills for the list)";
        }
        _begin_assistant_reply(app, line, expanded);
        return "";
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
