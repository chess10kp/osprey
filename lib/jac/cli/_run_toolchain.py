"""Pure functions from src/cli/run.ts — headless CLI argument parsing and formatting."""

from __future__ import annotations

import os
import sys

# Ensure agent dir is on path for dev_mode import
_pkg = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "agent")
if _pkg not in sys.path:
    sys.path.insert(0, _pkg)

from _dev_mode_toolchain import DEV_MODES, parse_mode_flag  # noqa: E402


# ── resolveRunMode ───────────────────────────────────────────────────

def resolve_run_mode(_cwd: str, cli_mode: str | None = None) -> str:
    """Resolve run mode from CLI flag or JACKAL_MODE env. Default 'auto-accept'.

    Differs from interactive boot (which defaults to 'normal' or .jackal config).
    """
    if cli_mode:
        return cli_mode

    env = os.environ.get("JACKAL_MODE", "").strip()
    if env and env in DEV_MODES:
        return env

    return "auto-accept"


# ── parseRunArgs ─────────────────────────────────────────────────────

def parse_run_args(argv: list[str]) -> dict:
    """Parse CLI arguments into an options dict.

    Returns ``{"ok": True, "options": {...}}`` or ``{"ok": False, "error": "..."}``.
    """
    args = argv[1:] if argv and argv[0] == "run" else list(argv)

    mode_parsed = parse_mode_flag(["dummy", *args])
    if isinstance(mode_parsed, dict) and "error" in mode_parsed:
        return {
            "ok": False,
            "error": f"invalid --mode '{mode_parsed['error']}' (expected {', '.join(DEV_MODES)})",
        }

    plain = False
    mode: str | None = mode_parsed if isinstance(mode_parsed, str) else None
    prompt_parts: list[str] = []

    i = 0
    while i < len(args):
        arg = args[i]

        if arg == "--plain":
            plain = True
            i += 1
            continue

        if arg == "--mode":
            i += 2  # skip --mode and its value
            continue
        if arg.startswith("--mode="):
            i += 1
            continue

        if arg.startswith("-"):
            return {"ok": False, "error": f"unknown flag: {arg}"}

        prompt_parts.append(arg)
        i += 1

    prompt = " ".join(prompt_parts).strip()
    if not prompt:
        return {
            "ok": False,
            "error": 'missing prompt (usage: jackal run [--plain] [--mode MODE] "prompt")',
        }

    return {"ok": True, "options": {"prompt": prompt, "plain": plain, "mode": mode}}


# ── formatToolLine ───────────────────────────────────────────────────

def _shorten(text: str, max_len: int) -> str:
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def format_tool_line(tool_name: str, input: dict | None = None) -> str:
    """Format a one-line tool display for headless mode."""
    if input is None:
        input = {}

    if tool_name == "read":
        path = input.get("path") or input.get("file_path")
        if path:
            return f"\u2692 Read {path}"
        return "\u2692 Read file"

    if tool_name in ("write", "edit"):
        path = input.get("path") or input.get("file_path")
        label = "Write" if tool_name == "write" else "Edit"
        if path:
            return f"\u2692 {label} {path}"
        return f"\u2692 {label} file"

    if tool_name == "bash":
        cmd = input.get("command")
        if cmd:
            return f"\u2692 Bash {_shorten(str(cmd), 72)}"
        return "\u2692 Bash"

    if tool_name == "web_search":
        q = input.get("search_term")
        if q:
            return f"\u2692 Search {_shorten(str(q), 60)}"
        return "\u2692 Web search"

    if tool_name == "web_fetch":
        url = input.get("url")
        if url:
            return f"\u2692 Fetch {_shorten(str(url), 60)}"
        return "\u2692 Fetch"

    if tool_name == "glob":
        pattern = input.get("pattern")
        if pattern:
            return f"\u2692 Glob {pattern}"
        return "\u2692 Glob"

    if tool_name == "agent":
        agent_name = input.get("agent")
        if agent_name:
            return f"\u2692 Subagent: {agent_name}"
        return "\u2692 Subagent"

    if tool_name == "edit":
        return "\u2692 Edit file"

    return f"\u2692 {tool_name}"


# ── lastAssistantText ────────────────────────────────────────────────

def last_assistant_text(messages: list[dict]) -> str:
    """Get last assistant text from a message list.

    Each message is a dict with ``role`` (str) and ``text`` (str).
    """
    for msg in reversed(messages):
        if not msg or not isinstance(msg, dict):
            continue
        if msg.get("role") == "assistant":
            text = msg.get("text", "")
            if isinstance(text, str) and text.strip():
                return text
    return ""


# ── approvalMessage ──────────────────────────────────────────────────

def approval_message(tool_name: str, subagent_name: str | None = None) -> str:
    """Format an approval-required message for headless mode."""
    if subagent_name:
        return f"Tool approval required for subagent '{subagent_name}': {tool_name}"
    return f"Tool approval required for: {tool_name}"
