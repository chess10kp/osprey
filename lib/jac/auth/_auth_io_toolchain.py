"""Auth file I/O helpers — load, save, resolve auth path.

Ported from src/auth/auth.ts (resolveAuthPath, loadAuthFile, saveAuthFile).
"""

from __future__ import annotations

import json
import os
import stat
from typing import Any


def resolve_auth_path(agent_dir: str | None = None) -> str:
    """Resolve the auth.json file path.

    Priority:
    1. JACKAL_AGENT_DIR env var
    2. agent_dir parameter
    3. ~/.jackal/

    Parameters
    ----------
    agent_dir : str | None
        Explicit JACKAL_AGENT_DIR override.

    Returns
    -------
    str
        Absolute path to auth.json.
    """
    base = agent_dir or os.environ.get("JACKAL_AGENT_DIR")
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".jackal")
    return os.path.join(base, "auth.json")


def load_auth_file(path: str) -> dict[str, Any]:
    """Load and parse an auth.json file.

    Returns empty dict if file doesn't exist or is invalid JSON.

    Parameters
    ----------
    path : str
        Absolute path to auth.json.

    Returns
    -------
    dict
        Parsed auth data (provider → credential dict).
    """
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


def save_auth_file(path: str, data: dict[str, Any]) -> None:
    """Save auth data to a JSON file with restricted permissions (0600).

    Creates parent directories with 0700 permissions if needed.

    Parameters
    ----------
    path : str
        Absolute path to auth.json.
    data : dict
        Auth data to save.
    """
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        os.makedirs(parent, mode=0o700, exist_ok=True)

    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, indent=2) + "\n")

    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)  # 0o600
    except OSError:
        pass


def get_auth_status(
    provider: str,
    stored_providers: dict[str, Any],
    runtime_keys: set[str] | None = None,
    env_api_key: str | None = None,
) -> dict[str, Any]:
    """Determine auth status for a provider.

    Parameters
    ----------
    provider : str
        Provider ID.
    stored_providers : dict
        Stored auth data (from auth.json).
    runtime_keys : set | None
        Runtime key overrides.
    env_api_key : str | None
        Environment variable API key, if present.

    Returns
    -------
    dict
        {configured: bool, source?: str, label?: str}
    """
    _runtime = runtime_keys or set()
    if provider in _runtime:
        return {"configured": True, "source": "stored", "label": "runtime override"}
    if provider in stored_providers:
        return {"configured": True, "source": "stored"}
    if env_api_key:
        return {"configured": True, "source": "environment", "label": "env"}
    return {"configured": False}
