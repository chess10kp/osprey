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


def boot_batch(cwd: str) -> dict:
    """Load all boot-time config in one call to avoid multiple subprocess spawns.

    Returns a dict with keys:
    - projectConfig: the parsed .jackal config
    - bootMode: resolved dev mode string
    - contextMax: context window override or None
    """
    config = load_project_config(cwd)
    mode = resolve_default_mode(config)
    ctx_max = config.get("contextMax")
    if not isinstance(ctx_max, (int, float)) or ctx_max <= 0:
        ctx_max = None
    return {
        "projectConfig": config,
        "bootMode": mode,
        "contextMax": ctx_max,
    }


def session_boot_batch(cwd: str, project_config: dict) -> dict:
    """Load session boot data in one call: always-allow tools, system prompt base.

    Parameters
    ----------
    cwd : str
        Project root.
    project_config : dict
        Pre-loaded project config (from boot_batch).

    Returns a dict with keys:
    - alwaysAllow: list of tool name strings
    - systemPromptBase: system prompt text (may be empty)
    """
    import sys as _sys
    import os as _os
    _root = _os.path.join(_os.getcwd(), "lib", "jac")
    for _sub in ("agent", "jac"):
        _p = _os.path.join(_root, _sub)
        if _p not in _sys.path:
            _sys.path.insert(0, _p)

    from _session_permissions_toolchain import load_always_allow_tools as _load_always_allow
    from _system_prompt_toolchain import load_system_prompt_base as _load_sys_prompt

    always_allow = _load_always_allow(cwd, project_config)
    sys_prompt = _load_sys_prompt(cwd)

    return {
        "alwaysAllow": always_allow,
        "systemPromptBase": sys_prompt,
    }
