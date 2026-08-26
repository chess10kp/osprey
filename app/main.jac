"""Jackal - all-Jac coding agent harness.

Two frontends, one session:
  term:  line REPL (default)
  json:  `--json` — JSONL protocol on stdio for UI clients (one JSON object
         per line; see json_event in agent/session.jac for the event set)
"""

import sys;
import os;
import json;
import from agent.session {
    run_turn,
    set_model,
    clear_history,
    model,
    json_event,
    list_commands,
    run_command,
    cancel_active_turn,
    get_history,
    restore_history,
    set_current_session_id,
    plugins,
    session_boot,
    session_dispose,
}
import from agent.sessions {
    list_sessions,
    latest_session_id,
    get_session_record,
    export_session,
    save_session,
    is_valid_session_id,
}


def print_banner {
    print("jackal - all-Jac agent harness");
    print(f"model: {model}   cwd: {os.getcwd()}");
    print("/help for commands, /exit to quit");
}


def print_help {
    print(
        "commands:\n"
        "  /help          this help\n"
        "  /model NAME    switch model (e.g. openrouter/anthropic/claude-sonnet-5)\n"
        "  /clear         clear conversation history\n"
        "  /abort         cancel the active turn (streaming or tool)\n"
        "  /sessions      list saved sessions\n"
        "  /resume [ID]   load a session transcript (default: latest)\n"
        "  /export [PATH] write the current transcript as markdown\n"
        "  /stats         toggle turn stats line (term mode)\n"
        "  /commands      list extension commands\n"
        "  /exit          quit"
    );
}


"""Handle a /command. Returns reply text, or None to exit, or '' for none."""
def handle_command(line: str) -> str | None {
    if line in ("/exit", "/quit") { return None; }
    if line == "/help" { print_help(); return ""; }
    if line == "/clear" { clear_history(); return "history cleared"; }
    if line == "/abort" {
        return "turn aborted" if cancel_active_turn() else "no active turn";
    }
    if line == "/sessions" {
        rows = list_sessions(os.getcwd());
        if not rows { return "no saved sessions"; }
        lines: list[str] = ["saved sessions:"];
        for row in rows[:20] {
            lines.append(
                "  " + str(row.get("id", "")) + "  "
                + str(row.get("name", ""))
            );
        }
        return "\n".join(lines);
    }
    if line.startswith("/resume") {
        arg = line[len("/resume"):].strip();
        sid: str = arg;
        if not sid {
            got = latest_session_id(os.getcwd());
            if got is None { return "no saved sessions to resume"; }
            sid = got;
        }
        rec: dict[str, any] | None = get_session_record(os.getcwd(), sid);
        if rec is None { return "unknown session: " + sid; }
        msgs: any = rec.get("messages", []);
        if not isinstance(msgs, list) or not msgs {
            return "session has no transcript: " + sid;
        }
        restore_history(msgs as list);
        rec_model: any = rec.get("model");
        reply: str = "resumed " + sid + " (" + str(len(msgs)) + " messages)";
        if isinstance(rec_model, str) and rec_model and rec_model != model {
            reply += "\nmodel -> " + set_model(rec_model);
        }
        return reply;
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
        if not has_content { return "nothing to export yet"; }
        # Export needs a saved record; persist the live transcript first.
        if not is_valid_session_id(str(plugins.session_id)) {
            set_current_session_id("");
        }
        try {
            meta = save_session(
                os.getcwd(), hist, session_id=plugins.session_id,
            );
        } except Exception as e {
            return "ERROR: could not save transcript: " + str(e);
        }
        if export_session(os.getcwd(), str(meta["id"]), path) {
            return "exported to " + path;
        }
        return "ERROR: could not write " + path;
    }
    if line == "/commands" {
        cmds = list_commands();
        if not cmds { return "no extension commands loaded"; }
        lines: list[str] = ["extension commands:"];
        for raw_name in sorted(cmds.keys()) {
            ent = cmds[raw_name];
            name = str(raw_name);
            desc = "";
            if isinstance(ent, dict) {
                got = ent.get("description", "");
                if isinstance(got, str) { desc = got; }
            }
            if desc {
                lines.append("  /" + name + "  " + desc);
            } else {
                lines.append("  /" + name);
            }
        }
        return "\n".join(lines);
    }
    if line.startswith("/model ") {
        name = line[len("/model "):].strip();
        if name { return "model -> " + set_model(name); }
        return "usage: /model NAME";
    }
    if line.startswith("/") {
        # Extension commands take precedence over the unknown-command error.
        parts = line[1:].split(None, 1);
        name = parts[0] if parts else "";
        args = parts[1].strip() if len(parts) > 1 else "";
        if name and name in list_commands() {
            return run_command(name, args);
        }
        hint = " (/commands for extension commands)";
        return "unknown command: " + line + " (/help for list)" + hint;
    }
    return "";
}


with entry:__main__ {
    # Pi lifecycle: boot loads .jackal/extensions.json and warms the Node
    # sidecar without blocking the first frame; run_turn awaits extension
    # readiness before the first model request.
    session_boot();
    json_mode = "--json" in sys.argv;
    if json_mode {
        json_event("session_ready", {"model": model, "cwd": os.getcwd()});
    } else {
        print_banner();
    }
    ended = False;
    try {
        while True {
            if json_mode {
                raw = sys.stdin.readline();
                if not raw { break; }
                raw_line: any = raw;
                text_in: str = str(raw_line).strip();
                if not text_in { continue; }
                try {
                    req: any = json.loads(text_in);
                } except ValueError {
                    json_event("error", {"message": "bad json: " + text_in[:80]});
                    continue;
                }
                text = str(req.get("text", ""));
                kind = str(req.get("type", "user"));
            } else {
                try {
                    text = input("\n> ").strip();
                } except EOFError {
                    print("");
                    break;
                } except KeyboardInterrupt {
                    print("");
                    continue;
                }
                if not text { continue; }
                kind = "command" if text.startswith("/") else "user";
            }
            if kind == "command" {
                reply = handle_command(text);
                if reply is None {
                    if json_mode { json_event("session_end", {}); ended = True; }
                    break;
                }
                if reply {
                    if json_mode { json_event("info", {"text": reply}); }
                    else { print(reply); }
                }
                continue;
            }
            try {
                if json_mode {
                    run_turn(text, json_event);
                } else {
                    run_turn(text);
                }
            } except KeyboardInterrupt {
                if json_mode { json_event("error", {"message": "interrupted"}); }
                else { print("\n[interrupted]"); }
            }
        }
    } finally {
        # Every exit path (EOF, /exit, fatal error) shuts extensions down:
        # session_shutdown hook fires, sidecar is disposed.
        session_dispose();
    }
    if json_mode {
        if not ended { json_event("session_end", {}); }
    } else { print("bye."); }
}
