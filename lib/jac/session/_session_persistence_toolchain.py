"""Session file persistence helpers — export, compaction backup, flush.

Pure-function extraction of file I/O from JackalSessionManager.
Messages follow the pi-agent-core AgentMessage shape:
    {role: str, content: str | list[ContentPart] | None}
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any


def _content_to_text(content: Any) -> str:
    """Extract displayable text from an AgentMessage content field."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict) and "text" in part:
                parts.append(str(part.get("text", "")))
            elif isinstance(part, dict):
                parts.append(json.dumps(part))
            else:
                parts.append(json.dumps(part))
        return "\n".join(parts)
    return json.dumps(content)


def _model_ref_str(model_ref: dict[str, str] | None) -> str:
    if model_ref and model_ref.get("provider") and model_ref.get("id"):
        return f"{model_ref['provider']}/{model_ref['id']}"
    return "(none)"


# ── Session directory ────────────────────────────────────────────────────


def session_dir_path(cwd: str, subdir: str | None = None) -> str:
    """Build session directory path. Defaults to ``<cwd>/.jackal/sessions``."""
    return os.path.join(cwd, ".jackal", subdir if subdir else "sessions")


# ── Markdown export ──────────────────────────────────────────────────────


def export_session_markdown(
    session_id: str,
    session_name: str,
    cwd: str,
    model_ref: dict[str, str] | None,
    messages: list[dict[str, Any]],
) -> str:
    """Generate a markdown export of a session.

    Parameters
    ----------
    session_id : str
    session_name : str
    cwd : str
        Working directory recorded in the session.
    model_ref : dict | None
        ``{provider: str, id: str}`` or ``None``.
    messages : list[dict]
        Each message has ``role`` and ``content`` (str | list | None).
    """
    lines: list[str] = [
        f"# {session_name}",
        "",
        f"- **Session ID:** {session_id}",
        f"- **Working directory:** {cwd}",
        f"- **Model:** {_model_ref_str(model_ref)}",
        f"- **Messages:** {len(messages)}",
        "",
        "---",
        "",
    ]

    for msg in messages:
        role = msg.get("role", "unknown")
        text = _content_to_text(msg.get("content"))
        lines.append(f"## {role}")
        lines.append("")
        lines.append(text)
        lines.append("")
        lines.append("---")
        lines.append("")

    return "\n".join(lines)


# ── Compaction backup ────────────────────────────────────────────────────


def _compaction_backup_path(session_dir: str, session_id: str) -> str:
    return os.path.join(session_dir, session_id, "compaction-backup.json")


def save_compaction_backup(
    session_dir: str,
    session_id: str,
    messages: list[dict[str, Any]],
) -> None:
    """Save a compaction backup JSON file under ``<session_dir>/<session_id>/``."""
    if not session_dir:
        return
    backup_dir = os.path.join(session_dir, session_id)
    os.makedirs(backup_dir, exist_ok=True)
    path = _compaction_backup_path(session_dir, session_id)
    payload = {
        "savedAt": datetime.now(timezone.utc).isoformat(),
        "messages": messages,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def load_compaction_backup(
    session_dir: str,
    session_id: str,
) -> list[dict[str, Any]] | None:
    """Load compaction backup messages. Returns *None* if absent or invalid."""
    path = _compaction_backup_path(session_dir, session_id)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            parsed = json.load(f)
        messages = parsed.get("messages") if isinstance(parsed, dict) else None
        return messages if isinstance(messages, list) else None
    except (json.JSONDecodeError, OSError):
        return None


def clear_compaction_backup(session_dir: str, session_id: str) -> None:
    """Clear (truncate) the compaction backup file. No-op if absent."""
    path = _compaction_backup_path(session_dir, session_id)
    if os.path.isfile(path):
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.truncate(0)
        except OSError:
            pass


# ── Flush session record ─────────────────────────────────────────────────


def flush_session_record(
    session_dir: str,
    session_id: str,
    session_name: str,
    cwd: str,
    created_at: str,
    messages: list[dict[str, Any]],
    model_ref: dict[str, str] | None,
) -> None:
    """Build a session record dict and delegate to ``save_session_record``.

    Parameters
    ----------
    session_dir : str
        Base sessions directory (e.g. ``.jackal/sessions``).
    session_id : str
        Must start with ``sess_``.
    session_name : str
    cwd : str
    created_at : str
        ISO-8601 timestamp.
    messages : list[dict]
    model_ref : dict | None
        ``{provider: str, id: str}`` or ``None``.
    """
    if not session_dir or not session_id.startswith("sess_"):
        return

    # Lazy import to avoid circular dependency at module level
    from _session_index_toolchain import save_session_record

    now = datetime.now(timezone.utc).isoformat()
    record: dict[str, Any] = {
        "sessionId": session_id,
        "sessionName": session_name,
        "cwd": cwd,
        "createdAt": created_at,
        "updatedAt": now,
        "model": model_ref,
        "messages": messages,
    }
    save_session_record(session_dir, record)
