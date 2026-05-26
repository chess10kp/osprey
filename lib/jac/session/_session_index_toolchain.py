"""Session index — list, load, save, delete, and prune sessions under .jackal/sessions/."""

from __future__ import annotations

import json
import math
import os
import re
from datetime import datetime, timezone
from typing import Any, TypedDict


INDEX_FILE = "index.json"

_SESSION_ID_RE = re.compile(r"^sess_\d+$")


# ── Types ─────────────────────────────────────────────────────────────


class ModelRef(TypedDict, total=False):
    provider: str
    id: str


class SessionIndexEntry(TypedDict, total=False):
    id: str
    name: str
    cwd: str
    updatedAt: str
    messageCount: int
    model: ModelRef | None


class SessionRecord(TypedDict, total=False):
    sessionId: str
    sessionName: str
    cwd: str
    createdAt: str
    updatedAt: str
    model: ModelRef | None
    messages: list[Any]


# ── Internal helpers ──────────────────────────────────────────────────


def is_valid_session_id(id_: str) -> bool:
    return bool(_SESSION_ID_RE.match(id_))


def _read_json_file(path: str) -> Any | None:
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _write_json_file(path: str, data: Any) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _is_index_entry(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    return (
        isinstance(value.get("id"), str)
        and isinstance(value.get("name"), str)
        and isinstance(value.get("cwd"), str)
        and isinstance(value.get("updatedAt"), str)
        and isinstance(value.get("messageCount"), (int, float))
    )


def is_session_record(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    return (
        isinstance(value.get("sessionId"), str)
        and isinstance(value.get("sessionName"), str)
        and isinstance(value.get("cwd"), str)
        and isinstance(value.get("updatedAt"), str)
        and isinstance(value.get("messages"), list)
    )


def _index_path(session_dir: str) -> str:
    return os.path.join(session_dir, INDEX_FILE)


def _session_file_path(session_dir: str, id_: str) -> str:
    return os.path.join(session_dir, f"{id_}.json")


def _read_index(session_dir: str) -> list[dict]:
    raw = _read_json_file(_index_path(session_dir))
    if not isinstance(raw, list):
        return _rebuild_index(session_dir)
    valid = [e for e in raw if _is_index_entry(e)]
    if len(valid) == 0 and len(raw) > 0:
        return _rebuild_index(session_dir)
    return valid


def _write_index(session_dir: str, entries: list[dict]) -> None:
    if not os.path.exists(session_dir):
        os.makedirs(session_dir, exist_ok=True)
    _write_json_file(_index_path(session_dir), entries)


def _rebuild_index(session_dir: str) -> list[dict]:
    if not os.path.exists(session_dir):
        return []
    entries: list[dict] = []
    try:
        names = os.listdir(session_dir)
    except OSError:
        return []
    for name in names:
        if not name.endswith(".json") or name == INDEX_FILE or name == "latest.json":
            continue
        id_ = name[:-5]
        if not is_valid_session_id(id_):
            continue
        record = _read_json_file(os.path.join(session_dir, name))
        if not is_session_record(record):
            continue
        entries.append({
            "id": record["sessionId"],
            "name": record["sessionName"],
            "cwd": record["cwd"],
            "updatedAt": record["updatedAt"],
            "messageCount": len(record["messages"]),
            "model": record.get("model"),
        })
    if entries:
        _write_index(session_dir, entries)
    return entries


def _parse_iso_ms(ts: str) -> float:
    """Parse an ISO timestamp string to epoch-milliseconds."""
    try:
        dt = datetime.fromisoformat(ts)
        return dt.timestamp() * 1000
    except (ValueError, TypeError):
        return 0.0


def _normalize_path(p: str) -> str:
    return os.path.normpath(os.path.realpath(p))


# ── Public API ────────────────────────────────────────────────────────


def read_json_file(path: str) -> Any | None:
    """Read and parse a JSON file; return None on missing/invalid."""
    return _read_json_file(path)


def write_json_file(path: str, data: Any) -> None:
    """Write data as pretty-printed JSON with trailing newline."""
    _write_json_file(path, data)


def is_index_entry(value: Any) -> bool:
    """Validate a SessionIndexEntry-shaped dict."""
    return _is_index_entry(value)


def rebuild_index(session_dir: str) -> list[dict]:
    """Rebuild index.json from session files on disk."""
    return _rebuild_index(session_dir)


def migrate_legacy_latest(session_dir: str, cwd: str) -> dict | None:
    """Migrate legacy latest.json into indexed per-session storage."""
    legacy_path = os.path.join(session_dir, "latest.json")
    if not os.path.exists(legacy_path):
        return None

    legacy = _read_json_file(legacy_path)
    if not isinstance(legacy, dict) or not isinstance(legacy.get("sessionId"), str):
        return None

    now = datetime.now(timezone.utc).isoformat()
    record: dict = {
        "sessionId": legacy["sessionId"],
        "sessionName": legacy.get("sessionName", "session"),
        "cwd": cwd,
        "createdAt": now,
        "updatedAt": now,
        "model": legacy.get("model"),
        "messages": legacy.get("messages", []),
    }

    save_session_record(session_dir, record)
    try:
        os.unlink(legacy_path)
    except OSError:
        pass
    return record


def save_session_record(session_dir: str, record: dict) -> None:
    """Save a session record file and update the index."""
    session_id = record.get("sessionId", "")
    if not is_valid_session_id(session_id):
        raise ValueError(f"Invalid session ID: {session_id}")
    if not os.path.exists(session_dir):
        os.makedirs(session_dir, exist_ok=True)

    _write_json_file(_session_file_path(session_dir, session_id), record)

    index = _read_index(session_dir)
    entry: dict = {
        "id": session_id,
        "name": record.get("sessionName", ""),
        "cwd": record.get("cwd", ""),
        "updatedAt": record.get("updatedAt", ""),
        "messageCount": len(record.get("messages", [])),
        "model": record.get("model"),
    }

    existing = next((i for i, e in enumerate(index) if e.get("id") == session_id), -1)
    if existing >= 0:
        index[existing] = entry
    else:
        index.append(entry)
    _write_index(session_dir, index)


def list_sessions(session_dir: str, options: dict | None = None) -> list[dict]:
    """List sessions sorted by updatedAt descending, optionally filtered by cwd."""
    if not os.path.exists(session_dir):
        return []
    entries = _read_index(session_dir)
    sorted_entries = sorted(entries, key=lambda e: _parse_iso_ms(e.get("updatedAt", "")), reverse=True)
    filter_cwd = (options or {}).get("cwd")
    if not filter_cwd:
        return sorted_entries
    normalized = _normalize_path(filter_cwd)
    return [e for e in sorted_entries if _normalize_path(e.get("cwd", "")) == normalized]


def load_session_by_id(session_dir: str, id_: str) -> dict | None:
    """Load a session record by its ID."""
    if not is_valid_session_id(id_):
        return None
    record = _read_json_file(_session_file_path(session_dir, id_))
    if is_session_record(record):
        return record
    return None


def resolve_session_target(session_dir: str, target: str, options: dict | None = None) -> dict | None:
    """Resolve 'last', numeric index (1-based), or raw session ID."""
    entries = list_sessions(session_dir, options)
    if not entries:
        return None

    lower = target.lower()
    if lower == "last":
        return load_session_by_id(session_dir, entries[0]["id"])

    try:
        index = int(target)
        if 1 <= index <= len(entries):
            return load_session_by_id(session_dir, entries[index - 1]["id"])
    except (ValueError, TypeError):
        pass

    return load_session_by_id(session_dir, target)


def get_last_session(session_dir: str, options: dict | None = None) -> dict | None:
    """Get the most recently updated session index entry."""
    entries = list_sessions(session_dir, options)
    return entries[0] if entries else None


def delete_session(session_dir: str, id_: str) -> bool:
    """Delete a session file and remove it from the index."""
    if not is_valid_session_id(id_):
        return False
    file = _session_file_path(session_dir, id_)
    if os.path.exists(file):
        try:
            os.unlink(file)
        except OSError:
            return False
    index = [e for e in _read_index(session_dir) if e.get("id") != id_]
    _write_index(session_dir, index)
    return True


def prune_sessions(session_dir: str, options: dict | None = None) -> list[str]:
    """Prune old sessions by count and/or retention days. Returns pruned IDs."""
    if not os.path.exists(session_dir):
        return []

    entries = _read_index(session_dir)
    if not entries:
        return []

    opts = options or {}
    now_ms = datetime.now(timezone.utc).timestamp() * 1000

    retention_days = opts.get("retentionDays")
    max_age_ms = (
        float(retention_days) * 24 * 60 * 60 * 1000
        if isinstance(retention_days, (int, float)) and retention_days > 0
        else math.inf
    )

    max_count_raw = opts.get("maxCount")
    max_count = (
        int(max_count_raw)
        if isinstance(max_count_raw, (int, float)) and max_count_raw > 0
        else math.inf
    )

    # Sort newest first
    sorted_entries = sorted(entries, key=lambda e: _parse_iso_ms(e.get("updatedAt", "")), reverse=True)

    pruned: list[str] = []

    for i, entry in enumerate(sorted_entries):
        age_ms = now_ms - _parse_iso_ms(entry.get("updatedAt", ""))
        if age_ms > max_age_ms or i >= max_count:
            file = _session_file_path(session_dir, entry["id"])
            try:
                if os.path.exists(file):
                    os.unlink(file)
                pruned.append(entry["id"])
            except OSError:
                pass

    if pruned:
        remaining = [e for e in sorted_entries if e["id"] not in pruned]
        _write_index(session_dir, remaining)

    return pruned
