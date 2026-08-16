"""Jackal - all-Jac coding agent harness (na-codespace pivot, phase N0).

Line-oriented REPL. `jac run na/main.jac` from the repo root, or
`cd na && jac run main.jac`.
"""

import sys;
import os;
import from agent.session { run_turn, set_model, clear_history, model }

def print_banner {
    model_name: str = model;
    print("jackal - all-Jac agent harness (N0)");
    print(f"model: {model_name}   cwd: {os.getcwd()}");
    print("/help for commands, /exit to quit");
}

def print_help {
    print(
        "commands:\n"
        "  /help          this help\n"
        "  /model NAME    switch model (e.g. openrouter/anthropic/claude-sonnet-4.6)\n"
        "  /clear         clear conversation history\n"
        "  /stats         toggle turn stats line\n"
        "  /exit          quit"
    );
}

with entry:__main__ {
    print_banner();
    while True {
        try {
            line = input("\n> ").strip();
        } except EOFError {
            print("");
            break;
        } except KeyboardInterrupt {
            print("");
            continue;
        }
        if not line { continue; }
        if line in ("/exit", "/quit") { break; }
        if line == "/help" { print_help(); continue; }
        if line == "/clear" { clear_history(); print("history cleared"); continue; }
        if line.startswith("/model ") {
            name = line[len("/model "):].strip();
            if name { print(f"model -> {set_model(name)}"); }
            continue;
        }
        if line.startswith("/") {
            print(f"unknown command: {line} (/help for list)");
            continue;
        }
        try {
            run_turn(line);
        } except KeyboardInterrupt {
            print("\n[interrupted]");
        }
    }
    print("bye.");
}
