"""Project config loader — walk-up .jackal finder + default mode resolver (Phase 2A.1)."""

from __future__ import annotations

import json
from pathlib import Path

VALID_MODES = ("normal", "auto-accept", "yolo", "plan", "ask")


def find_config_path(cwd: str) -> str | None:
    """Walk up from *cwd* looking for a ``.jackal`` file. Return absolute path or ``None``."""
    cur = Path(cwd).resolve()
    while True:
        cand = cur / ".jackal"
        if cand.is_file():
            return str(cand)
        parent = cur.parent
        if parent == cur:
            return None
        cur = parent


def load_project_config(cwd: str) -> dict:
    """Load and parse the ``.jackal`` JSON config for *cwd*. Returns ``{}`` on miss/parse error."""
    config_path = find_config_path(cwd)
    if not config_path:
        return {}
    try:
        parsed = json.loads(Path(config_path).read_text(encoding="utf-8"))
        if isinstance(parsed, dict):
            return parsed
    except (OSError, json.JSONDecodeError):
        pass
    return {}


def resolve_default_mode(config: dict) -> str:
    """Derive boot mode from config (``mode`` key → legacy ``plan: true`` → ``"normal"``)."""
    mode = config.get("mode")
    if isinstance(mode, str) and mode in VALID_MODES:
        return mode
    if config.get("plan"):
        return "plan"
    return "normal"
