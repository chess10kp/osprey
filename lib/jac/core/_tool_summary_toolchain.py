"""Tool input normalization and compact display labels for the Ink transcript.

Pure functions with no runtime dependencies. Each accepts plain Python types
(dict, str, None) and returns plain Python types.
"""

from __future__ import annotations

import json
from typing import Any, Mapping, Optional


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _truncate(text: str, max_len: int) -> str:
    """Truncate *text* to *max_len* chars, appending an ellipsis if needed."""
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "…"


# ---------------------------------------------------------------------------
# Input normalization
# ---------------------------------------------------------------------------

def normalize_tool_input(raw: Any) -> Optional[dict[str, Any]]:
    """Normalize a tool input value to a plain dict, or ``None``.

    * ``None`` → ``None``
    * A JSON object string (``{…}``) → parsed dict
    * A dict → returned as-is
    * Anything else → ``None``
    """
    if raw is None:
        return None

    if isinstance(raw, str):
        trimmed = raw.strip()
        if not trimmed:
            return None
        if trimmed.startswith("{") or trimmed.startswith("["):
            try:
                parsed = json.loads(trimmed)
                if isinstance(parsed, dict):
                    return parsed
            except (json.JSONDecodeError, ValueError):
                pass
        return None

    if isinstance(raw, dict):
        return raw

    return None


def tool_input_field(
    input: Optional[Mapping[str, Any]],
    key: str,
) -> str:
    """Return ``input[key]`` as a string, or ``""`` if absent / null."""
    if not input:
        return ""
    val = input.get(key)
    if val is not None:
        return str(val)
    return ""


def tool_bash_command(input: Optional[Mapping[str, Any]]) -> str:
    """Extract the bash command from an input dict (``command`` or ``cmd``)."""
    cmd = tool_input_field(input, "command")
    return cmd or tool_input_field(input, "cmd")


def tool_file_path(input: Optional[Mapping[str, Any]]) -> str:
    """Extract a file path from an input dict, trying several field names."""
    return (
        tool_input_field(input, "path")
        or tool_input_field(input, "file_path")
        or tool_input_field(input, "target_file")
        or tool_input_field(input, "file")
    )


# ---------------------------------------------------------------------------
# Compact tool summary
# ---------------------------------------------------------------------------

def format_tool_summary(
    tool_name: str,
    input: Optional[Mapping[str, Any]] = None,
) -> str:
    """Return a one-line compact label for a tool row in the TUI transcript.

    This mirrors ``src/core/tool-summary.ts`` ``formatToolSummary`` exactly.
    """
    if tool_name == "read":
        path = tool_file_path(input)
        if path:
            return f"Read @ {_truncate(path, 60)}"
        return "Read file"

    if tool_name == "write":
        path = tool_file_path(input)
        if path:
            return f"Wrote → {_truncate(path, 60)}"
        return "Wrote file"

    if tool_name == "edit":
        path = tool_file_path(input)
        if path:
            return f"Edited {_truncate(path, 60)}"
        return "Edited file"

    if tool_name == "bash":
        cmd = tool_bash_command(input)
        if cmd:
            return f"$ {_truncate(cmd, 60)}"
        return "Ran shell command"

    if tool_name == "glob":
        pattern = tool_input_field(input, "pattern")
        if pattern:
            return f"Glob {_truncate(pattern, 60)}"
        return "File search"

    if tool_name == "agent":
        task = tool_input_field(input, "task") or tool_input_field(input, "prompt")
        if task:
            return f"Subagent: {_truncate(task, 50)}"
        return "Delegated to subagent"

    if tool_name == "update_task":
        updates = input.get("updates") if input else None
        if isinstance(updates, list) and len(updates) > 0:
            first = updates[0]
            first_dict = first if isinstance(first, dict) else {}
            uid = tool_input_field(first_dict, "id")
            status = tool_input_field(first_dict, "status")
            extra = f" (+{len(updates) - 1})" if len(updates) > 1 else ""
            if uid and status:
                return f"Task {uid} → {status}{extra}"
            if uid:
                return f"Updated task {uid}{extra}"
        return "Updated task"

    if tool_name == "create_task":
        title = tool_input_field(input, "title")
        if title:
            return f"Created task: {_truncate(title, 50)}"
        return "Created task"

    if tool_name == "mermaid":
        return "Rendered diagram"

    if tool_name in ("jac_check", "jac_check_syntax"):
        return "Ran jac check"

    if tool_name == "jac_run":
        file = tool_input_field(input, "file") or tool_file_path(input)
        if file:
            return f"Ran jac {_truncate(file, 50)}"
        return "Ran jac file"

    if tool_name == "jac_format":
        return "Formatted jac file(s)"

    if tool_name == "jac_test":
        return "Ran jac test"

    if tool_name == "jac_fix":
        return "Ran jac fix loop"

    if tool_name == "jac_doctor":
        return "Ran jac doctor"

    if tool_name == "jac_create":
        return "Ran jac create"

    if tool_name == "jac_cli":
        args = input.get("args") if input else None
        if isinstance(args, (list, tuple)) and len(args) > 0:
            return f"jac {_truncate(' '.join(str(a) for a in args), 55)}"
        return "Ran jac CLI"

    if tool_name == "diagnostics":
        return "Got diagnostics"

    if tool_name == "hover":
        return "Looked up type info"

    if tool_name == "definition":
        return "Found definition"

    if tool_name == "references":
        return "Found references"

    if tool_name == "web_search":
        q = tool_input_field(input, "search_term") or tool_input_field(input, "query")
        if q:
            return f"Web search: {_truncate(q, 55)}"
        return "Web search"

    if tool_name == "web_fetch":
        url = tool_input_field(input, "url")
        if url:
            return f"Fetched {_truncate(url, 55)}"
        return "Fetched URL"

    if tool_name.startswith("jac_"):
        return f"Ran {tool_name}"

    return f"Ran {tool_name}"


# ---------------------------------------------------------------------------
# Enrichment from result.details
# ---------------------------------------------------------------------------

_PATH_TOOLS = frozenset({"read", "write", "edit", "jac_run"})


def enrich_tool_input_from_result(
    tool_name: str,
    input: Optional[Mapping[str, Any]],
    result: Any,
) -> Optional[dict[str, Any]]:
    """Pull path / command from *result.details* when start args were missing.

    Returns a (possibly new) dict with the enriched input, or the original
    *input* unchanged when no enrichment was possible.
    """
    if tool_name in _PATH_TOOLS and tool_file_path(input):
        return dict(input) if input else None

    if tool_name == "bash" and tool_bash_command(input):
        return dict(input) if input else None

    if not result or not isinstance(result, dict):
        return dict(input) if input else None

    details = result.get("details")
    if not details or not isinstance(details, dict):
        return dict(input) if input else None

    merged: dict[str, Any] = dict(input) if input else {}

    if not tool_file_path(merged):
        path = (
            tool_input_field(details, "path")
            or tool_input_field(details, "file")
            or tool_input_field(details, "target_file")
        )
        if path:
            merged["path"] = path

    if tool_name == "bash" and not tool_bash_command(merged):
        cmd = tool_input_field(details, "command")
        if cmd:
            merged["command"] = cmd

    return merged


# ---------------------------------------------------------------------------
# Event helpers
# ---------------------------------------------------------------------------

def tool_event_input(event: Mapping[str, Any]) -> Optional[dict[str, Any]]:
    """Extract the tool input dict from a tool event payload.

    Tries ``event["input"]`` first, then ``event["args"]``.
    """
    return normalize_tool_input(event.get("input", event.get("args")))
