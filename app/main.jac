"""Jackal - all-Jac coding agent harness.

Two frontends, one session:
  term:  line REPL (default)
  json:  `--json` — JSONL protocol on stdio for UI clients (one JSON object
         per line; see json_event in agent/session.jac for the event set)
"""

import sys;
import os;
import json;
import from agent.session { run_turn, set_model, clear_history, model, json_event }


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
        "  /stats         toggle turn stats line (term mode)\n"
        "  /exit          quit"
    );
}


"""Handle a /command. Returns reply text, or None to exit, or '' for none."""
def handle_command(line: str) -> str | None {
    if line in ("/exit", "/quit") { return None; }
    if line == "/help" { print_help(); return ""; }
    if line == "/clear" { clear_history(); return "history cleared"; }
    if line.startswith("/model ") {
        name = line[len("/model "):].strip();
        if name { return "model -> " + set_model(name); }
        return "usage: /model NAME";
    }
    if line.startswith("/") {
        return "unknown command: " + line + " (/help for list)";
    }
    return "";
}


with entry:__main__ {
    json_mode = "--json" in sys.argv;
    if json_mode {
        json_event("session_ready", {"model": model, "cwd": os.getcwd()});
    } else {
        print_banner();
    }
    ended = False;
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
    if json_mode {
        if not ended { json_event("session_end", {}); }
    } else { print("bye."); }
}
