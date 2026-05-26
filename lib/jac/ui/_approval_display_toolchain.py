"""Approval display — human-readable summaries for tool approval UI."""

from __future__ import annotations

import json

MAX_PREVIEW_CHARS = 1200
MAX_LINE_CHARS = 100
MAX_WRITE_PREVIEW_LINES = 12
MAX_EDIT_PREVIEW_LINES = 16


def _truncate(text: str, max_len: int = MAX_PREVIEW_CHARS) -> str:
    if len(text) <= max_len:
        return text
    return text[:max_len] + "…"


def _one_line(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return " ".join(value.split())
    return json.dumps(value, ensure_ascii=False)


def _bash_command(params: dict) -> str | None:
    cmd = params.get("command") or params.get("cmd")
    return cmd if isinstance(cmd, str) else None


def _file_path(params: dict) -> str | None:
    for key in ("path", "file", "file_path", "target_file"):
        v = params.get(key)
        if isinstance(v, str) and v.strip():
            return v
    return None


def _collect_edits(params: dict) -> list[dict]:
    out: list[dict] = []

    edits = params.get("edits")
    if isinstance(edits, list):
        for e in edits:
            if not isinstance(e, dict):
                continue
            old_text = e.get("oldText") or e.get("old_string") or e.get("old_str")
            new_text = e.get("newText") or e.get("new_string") or e.get("new_str")
            if isinstance(old_text, str) and isinstance(new_text, str):
                out.append({"oldText": old_text, "newText": new_text})

    single_old = params.get("old_string") or params.get("oldText") or params.get("old_str")
    single_new = params.get("new_string") or params.get("newText") or params.get("new_str")
    if isinstance(single_old, str) and isinstance(single_new, str):
        out.append({"oldText": single_old, "newText": single_new})

    return out


def _push_block(
    lines: list[dict], block: str, tone: str, max_lines: int
) -> None:
    parts = block.split("\n")
    limit = min(len(parts), max_lines)
    for i in range(limit):
        t = parts[i].rstrip()
        if t:
            lines.append({"text": t, "tone": tone})
    if len(parts) > max_lines:
        lines.append({"text": f"… ({len(parts) - max_lines} more lines)", "tone": "muted"})


def _append_edit_preview(lines: list[dict], edits: list[dict]) -> None:
    if not edits:
        return
    for i, edit in enumerate(edits):
        if len(edits) > 1:
            lines.append({"text": f"Edit {i + 1}:", "tone": "accent"})
        lines.append({"text": "− remove:", "tone": "muted"})
        _push_block(lines, edit["oldText"], "removed", MAX_EDIT_PREVIEW_LINES)
        lines.append({"text": "+ add:", "tone": "muted"})
        _push_block(lines, edit["newText"], "added", MAX_EDIT_PREVIEW_LINES)


def _append_write_preview(lines: list[dict], params: dict) -> None:
    content = params.get("content")
    if not isinstance(content, str) or not content:
        return
    lines.append({"text": "Content preview:", "tone": "accent"})
    _push_block(lines, content, "default", MAX_WRITE_PREVIEW_LINES)


_SKIP_KEYS = frozenset([
    "command", "cmd", "path", "file", "file_path", "target_file",
    "old_string", "new_string", "oldText", "newText", "old_str", "new_str",
    "edits", "content",
])


def format_approval_display(
    tool_name: str,
    params: dict,
    subagent_name: str | None = None,
) -> dict:
    """Return {headline, question, detailLines, previewLines}."""
    preview: list[dict] = []
    detail: list[str] = []

    if subagent_name and subagent_name.strip():
        sub = subagent_name.strip()
        detail.append(f"Subagent: {sub}")
        preview.append({"text": f"Subagent: {sub}", "tone": "accent"})

    command = _bash_command(params)
    if command:
        detail.append(f"Command: {_truncate(command, MAX_LINE_CHARS)}")
        preview.append({"text": "Command:", "tone": "muted"})
        preview.append({"text": command, "tone": "accent"})

    fpath = _file_path(params)
    if fpath:
        detail.append(f"Path: {fpath}")
        if not command:
            preview.append({"text": f"Path: {fpath}", "tone": "accent"})

    if tool_name in ("edit", "string_replace"):
        edits = _collect_edits(params)
        _append_edit_preview(preview, edits)
        for edit in edits:
            detail.append(f"Remove: {_truncate(_one_line(edit['oldText']), MAX_LINE_CHARS)}")
            detail.append(f"Add: {_truncate(_one_line(edit['newText']), MAX_LINE_CHARS)}")

    if tool_name == "write":
        _append_write_preview(preview, params)
        content = params.get("content")
        if isinstance(content, str):
            detail.append(f"Bytes: {len(content)}")

    # MCP / Jac hint
    if tool_name.startswith("mcp_") or tool_name.startswith("jac_"):
        label = "MCP tool" if tool_name.startswith("mcp_") else "Jac tool"
        preview.append({"text": label, "tone": "muted"})

    # Remaining params
    rest = {k: v for k, v in params.items() if k not in _SKIP_KEYS}
    if rest:
        try:
            snippet = _truncate(json.dumps(rest, ensure_ascii=False, indent=2))
        except Exception:
            snippet = _truncate(str(rest))
        detail.append(snippet)
        preview.append({"text": snippet, "tone": "default"})
    elif len(detail) == (1 if subagent_name else 0) and len(preview) == (1 if subagent_name else 0):
        try:
            snippet = _truncate(json.dumps(params, ensure_ascii=False, indent=2))
        except Exception:
            snippet = "(no parameters)"
            preview.append({"text": "(no parameters)", "tone": "muted"})
            detail.append(snippet)
            if "(no parameters)" not in snippet:
                preview.append({"text": snippet, "tone": "default"})

    # Headline + question
    headline = tool_name
    if command:
        headline = f"{tool_name} — shell command"
    elif fpath:
        headline = f"{tool_name} — {fpath}"

    tool_label = f'subagent tool "{tool_name}"' if subagent_name else f'tool "{tool_name}"'
    question = f"Execute {tool_label}?" if command else f"Allow {tool_label} to run?"

    return {
        "headline": headline,
        "question": question,
        "detailLines": detail,
        "previewLines": preview,
    }
