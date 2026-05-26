"""Dev mode logic — tool approval policy, plan/ask mode filtering, mode cycling."""

from __future__ import annotations

DEV_MODES = ("normal", "auto-accept", "yolo", "plan", "ask")

READ_ONLY_MODE_BLOCKED_TOOLS = frozenset([
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
])

PLAN_MODE_SYSTEM_APPENDIX = """

## Plan mode (active)

You are in **plan mode**: explore, analyze, and produce a clear implementation plan. You must **not** modify project source files.

- Use read, web_search, web_fetch, diagnostics, `jac check`, tests, bash, LSP, and MCP read tools freely.
- Do **not** call `write`, `edit`, format/fix/create tools, or task mutations — they are blocked.
- Output a numbered plan the user can approve; tell them to switch out of plan mode (Shift+Tab) to implement.
"""

ASK_MODE_SYSTEM_APPENDIX = """

## Ask mode (active)

You are in **ask mode**: answer questions, explain code, and explore the codebase. You must **not** modify project source files.

- Use read, web_search, web_fetch, diagnostics, `jac check`, tests, bash, LSP, and MCP read tools freely.
- Do **not** call `write`, `edit`, format/fix/create tools, or task mutations — they are blocked.
- Give clear, direct answers with code citations when helpful; tell the user to switch out of ask mode (Shift+Tab) to apply changes.
"""

_DESTRUCTIVE_BASH_PATTERNS = [
    r"rm\s+-rf\s+\/(?!\w)",
    r"\brm\s+-rf\s+~\b",
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
]

import re as _re

_DESTRUCTIVE_COMPILED = [_re.compile(p, _re.IGNORECASE) for p in _DESTRUCTIVE_BASH_PATTERNS]


def is_read_only_mode(mode: str) -> bool:
    return mode in ("plan", "ask")


def read_only_mode_block_reason(tool_name: str, mode: str) -> str:
    if mode == "ask":
        return f'Tool "{tool_name}" cannot modify files in ask mode. Switch to normal mode (Shift+Tab) to make changes.'
    return f'Tool "{tool_name}" cannot modify files in plan mode. Switch to normal mode (Shift+Tab) to implement changes.'


def is_tool_blocked_in_read_only_mode(tool_name: str) -> bool:
    return tool_name in READ_ONLY_MODE_BLOCKED_TOOLS


def is_tool_blocked_in_plan_mode(tool_name: str) -> bool:
    return is_tool_blocked_in_read_only_mode(tool_name)


def cycle_mode(current: str) -> str:
    idx = DEV_MODES.index(current) if current in DEV_MODES else -1
    next_idx = (idx + 1) % len(DEV_MODES) if idx >= 0 else 0
    return DEV_MODES[next_idx]


def parse_mode_flag(args: list[str]) -> str | dict | None:
    for i, arg in enumerate(args):
        raw = None
        if arg == "--mode" and i + 1 < len(args):
            raw = args[i + 1]
        elif arg.startswith("--mode="):
            raw = arg[len("--mode=") :]

        if raw is None:
            continue

        if raw in DEV_MODES:
            return raw
        return {"error": raw}
    return None


def is_tool_allowed_in_plan_mode(tool_name: str) -> bool:
    return not is_tool_blocked_in_plan_mode(tool_name)


def system_prompt_for_mode(base_prompt: str, mode: str) -> str:
    if mode == "plan":
        if "## Plan mode (active)" in base_prompt:
            return base_prompt
        return base_prompt + PLAN_MODE_SYSTEM_APPENDIX
    if mode == "ask":
        if "## Ask mode (active)" in base_prompt:
            return base_prompt
        return base_prompt + ASK_MODE_SYSTEM_APPENDIX
    return base_prompt


def is_destructive_bash(cmd: str) -> bool:
    command = cmd.strip()
    if not command:
        return False
    return any(pattern.search(command) for pattern in _DESTRUCTIVE_COMPILED)


def _bash_command_from_params(tool_name: str, params: dict) -> str:
    if tool_name == "bash":
        return str(params.get("command", ""))
    if tool_name == "jac_cli":
        args = params.get("args")
        if isinstance(args, list):
            return "jac " + " ".join(str(a) for a in args)
    return ""


def should_auto_approve(mode: str, tool_name: str, params: dict) -> bool:
    if mode == "yolo":
        return True

    if mode in ("plan", "ask"):
        return not is_tool_blocked_in_read_only_mode(tool_name)

    if mode == "auto-accept":
        shell_cmd = _bash_command_from_params(tool_name, params)
        if shell_cmd:
            return not is_destructive_bash(shell_cmd)
        return True

    # normal — confirm every tool call
    return False
