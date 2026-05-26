"""Adapter pure helpers — context window resolution and session storage path.

Ported from src/core/adapter.ts (resolveContextMax, sessionStorageDir).
"""

from __future__ import annotations

import os
from typing import Any


def resolve_context_max(
    cwd: str,
    options: dict[str, Any] | None = None,
    env_value: str | None = None,
    project_config: dict[str, Any] | None = None,
) -> int | None:
    """Resolve the context window maximum token count.

    Priority order:
    1. options["contextMax"] (explicit parameter)
    2. JACKAL_CONTEXT_MAX env var
    3. .jackal config contextMax
    4. None (use model default)

    Parameters
    ----------
    cwd : str
        Working directory (for config lookup).
    options : dict | None
        Adapter options dict; may contain ``"contextMax"``.
    env_value : str | None
        JACKAL_CONTEXT_MAX value (pass from env to keep pure).
    project_config : dict | None
        Pre-loaded .jackal config; may contain ``"contextMax"``.

    Returns
    -------
    int | None
        Context max tokens, or None if not configured.
    """
    # 1. Explicit parameter
    if options and isinstance(options.get("contextMax"), (int, float)):
        val = options["contextMax"]
        if val and val > 0:
            return int(val)

    # 2. Environment variable
    if env_value:
        try:
            parsed = int(env_value)
            if parsed > 0:
                return parsed
        except (ValueError, TypeError):
            pass

    # 3. Project config
    if project_config and isinstance(project_config.get("contextMax"), (int, float)):
        val = project_config["contextMax"]
        if val and val > 0:
            return int(val)

    return None


def session_storage_dir(cwd: str, override: str | None = None) -> str:
    """Resolve the session storage directory path.

    Parameters
    ----------
    cwd : str
        Working directory.
    override : str | None
        Explicit override path.

    Returns
    -------
    str
        Absolute path to session storage directory.
    """
    if override:
        return override
    return os.path.join(cwd, ".jackal", "sessions")
