"""Dev-mode safety logic (ported from lib/jac/agent/_dev_mode_toolchain.py).

Pure logic only: no I/O, no graph/UI dependencies. Modes cycle
normal -> auto-accept -> yolo -> plan -> ask -> normal. Read-only modes
(plan/ask) block the write-family tool set; approval policy resolution is
table-driven per mode.

Tool-name divergence vs the Python original (which serves the TypeScript
harness): this app harness's tools live in agent/tools.jac as
read_file/write_file/edit_file/list_dir/run_command. The blocked set below
therefore contains BOTH the original names (write, edit, jac_format,
jac_fix, jac_create, create_task, update_task, delete_task, format_jac,
execute_command) and their harness equivalents (write_file, edit_file).
run_command is NOT blanket-blocked: like `bash` in the original, shell
commands stay usable in plan/ask but destructive ones are refused
(see requires_approval).
"""

import re;

glob DEV_MODES: list[str] = ["normal", "auto-accept", "yolo", "plan", "ask"];

glob READ_ONLY_MODES: list[str] = ["plan", "ask"];

glob READ_ONLY_MODE_BLOCKED_TOOLS: set[str] = {
    "write",
    "edit",
    "jac_format",
    "jac_fix",
    "jac_create",
    "create_task",
    "update_task",
    "delete_task",
    "format_jac",
    "execute_command",
    # Harness-native equivalents (see module docstring).
    "write_file",
    "edit_file",
};

glob PLAN_MODE_SYSTEM_APPENDIX: str = """

## Plan mode (active)

You are in **plan mode**: explore, analyze, and produce a clear implementation plan. You must **not** modify project source files.
""";

glob ASK_MODE_SYSTEM_APPENDIX: str = """

## Ask mode (active)

You are in **ask mode**: answer questions, explain code, and explore the codebase. You must **not** modify project source files.
""";

glob DESTRUCTIVE_BASH_PATTERNS: list[str] = [
    r"rm\s+-rf\s+\/(?!\w)",
    # Divergence vs Python/TS originals: those use r"\brm\s+-rf\s+~\b", whose
    # trailing \b can never match (~ and end-of-string are both non-word), so
    # "rm -rf ~" went undetected. Trailing boundary dropped here.
    r"\brm\s+-rf\s+~",
    r"\brm\s+-rf\s+\$\{?HOME\}?",
    r"\bmkfs\b",
    r"\bdd\s+if=",
    r":\(\)\{:\|:&\};:",
    r">\s*\/dev\/sd[a-z]",
    r"\bchmod\s+-R\s+000\b",
    r"\bgit\s+reset\s+--hard\b",
    r"\bgit\s+push\s+(--force|-f)\b",
    r"\bgit\s+clean\s+-[a-z]*f",
    r"\bgit\s+branch\s+-[dD]\s+",
    r"\bgit\s+stash\s+(drop|clear)\b",
    r"\bgit\s+reflog\s+expire\b",
    r"\bgit\s+filter-branch\b",
    r"\bdrop\s+database\b",
    r"\btruncate\s+table\b",
];


"""True when the mode restricts the session to read-only behavior."""
def is_read_only_mode(mode: str) -> bool {
    return mode in READ_ONLY_MODES;
}


"""True when a tool is on the read-only-mode blocked list."""
def is_tool_blocked_in_read_only_mode(tool_name: str) -> bool {
    return tool_name in READ_ONLY_MODE_BLOCKED_TOOLS;
}


"""True when the given mode blocks the given tool."""
def is_tool_blocked(mode: str, tool_name: str) -> bool {
    return is_read_only_mode(mode) and is_tool_blocked_in_read_only_mode(tool_name);
}


"""Human-facing reason string for a blocked tool in a read-only mode."""
def read_only_mode_block_reason(tool_name: str, mode: str) -> str {
    if mode == "ask" {
        return 'Tool "' + tool_name + '" cannot modify files in ask mode. Switch to normal mode (Shift+Tab) to make changes.';
    }
    return 'Tool "' + tool_name + '" cannot modify files in plan mode. Switch to normal mode (Shift+Tab) to implement changes.';
}


"""Advance the Shift+Tab mode cycle; unknown modes reset to normal."""
def cycle_mode(current: str) -> str {
    idx = -1;
    for i in range(len(DEV_MODES)) {
        if DEV_MODES[i] == current {
            idx = i;
            break;
        }
    }
    if idx < 0 {
        return DEV_MODES[0];
    }
    return DEV_MODES[(idx + 1) % len(DEV_MODES)];
}


"""Parse a --mode[=value] CLI flag; invalid values yield {"error": raw}."""
def parse_mode_flag(args: list[str]) -> str | dict[str, str] | None {
    for i in range(len(args)) {
        raw: str | None = None;
        arg = args[i];
        if arg == "--mode" and i + 1 < len(args) {
            raw = args[i + 1];
        } elif arg.startswith("--mode=") {
            raw = arg[len("--mode="):];
        }
        if raw is None {
            continue;
        }
        if raw in DEV_MODES {
            return raw;
        }
        return {"error": raw};
    }
    return None;
}


"""True when the shell command matches a destructive-bash pattern."""
def is_destructive_bash(cmd: str) -> bool {
    command = cmd.strip();
    if not command {
        return False;
    }
    for pattern in DESTRUCTIVE_BASH_PATTERNS {
        if re.search("(?i)" + pattern, command) is not None {
            return True;
        }
    }
    return False;
}


"""Appendix text the system prompt gains in plan/ask modes."""
def system_prompt_for_mode(base_prompt: str, mode: str) -> str {
    if mode == "plan" {
        if "## Plan mode (active)" in base_prompt {
            return base_prompt;
        }
        return base_prompt + PLAN_MODE_SYSTEM_APPENDIX;
    }
    if mode == "ask" {
        if "## Ask mode (active)" in base_prompt {
            return base_prompt;
        }
        return base_prompt + ASK_MODE_SYSTEM_APPENDIX;
    }
    return base_prompt;
}


"""Resolve the approval policy for a tool call under a mode.

Returns one of:
  "blocked" — refuse the call (read-only mode, write-family tool);
  "auto"    — execute without prompting;
  "confirm" — require explicit user approval.
Unknown modes fall back to normal-mode semantics (always confirm).
"""
def requires_approval(mode: str, tool_name: str, cmd: str) -> str {
    if is_tool_blocked(mode, tool_name) {
        return "blocked";
    }
    if mode == "yolo" {
        return "auto";
    }
    if mode == "auto-accept" {
        if tool_name == "run_command" or tool_name == "bash" {
            if is_destructive_bash(cmd) {
                return "confirm";
            }
        }
        return "auto";
    }
    if mode == "plan" or mode == "ask" {
        # Shell stays available in read-only modes (mirrors the original's
        # "use bash freely"), but destructive commands are refused outright.
        if (tool_name == "run_command" or tool_name == "bash") and is_destructive_bash(cmd) {
            return "blocked";
        }
        return "auto";
    }
    return "confirm";
}
