"""Path resolution and safety helpers for tool execution.

Ported from src/agent/tools.ts (safeResolve, resolveReadPath, formatPostWriteMessage).
"""

from __future__ import annotations

import os
from typing import Any


def safe_resolve(cwd: str, input_path: str) -> str:
    """Resolve *input_path* against *cwd*, rejecting paths that escape cwd.

    Returns an absolute, normalised path.
    Raises ValueError if the resolved path escapes the cwd tree.
    """
    abs_path = os.path.normpath(input_path) if os.path.isabs(input_path) else os.path.normpath(os.path.join(cwd, input_path))
    root = os.path.normpath(cwd + os.sep)
    if not (abs_path + os.sep).startswith(root) and abs_path != os.path.normpath(cwd):
        raise ValueError(f"Path escapes cwd: {input_path}")
    return abs_path


def resolve_read_path(
    cwd: str,
    input_path: str,
    allow_files: set[str] | None = None,
    allow_roots: set[str] | None = None,
) -> str:
    """Resolve a read path, optionally allowing paths outside cwd via allowlists.

    Parameters
    ----------
    cwd : str
        Working directory root.
    input_path : str
        User-supplied path.
    allow_files : set[str] | None
        Explicit set of absolute paths that are allowed.
    allow_roots : set[str] | None
        Set of absolute directory prefixes that are allowed.

    Returns
    -------
    str
        Absolute, normalised path.

    Raises
    ------
    ValueError
        If the path escapes cwd and is not in the allowlists.
    """
    abs_path = os.path.normpath(input_path) if os.path.isabs(input_path) else os.path.normpath(os.path.join(cwd, input_path))
    root = os.path.normpath(cwd + os.sep)
    if (abs_path + os.sep).startswith(root) or abs_path == os.path.normpath(cwd):
        return abs_path

    _files = allow_files or set()
    _roots = allow_roots or set()

    if abs_path in _files:
        return abs_path
    for skill_root in _roots:
        if (abs_path + os.sep).startswith(skill_root):
            return abs_path

    raise ValueError(f"Path escapes cwd: {input_path}")


def format_post_write_message(action: str, path: str, notes: list[str] | None = None) -> str:
    """Format a post-write/edit message with optional auto-format/check notes.

    Parameters
    ----------
    action : str
        ``"Wrote"`` or ``"Edited"``.
    path : str
        File path that was written or edited.
    notes : list[str] | None
        Optional list of auto-format / auto-check notes.

    Returns
    -------
    str
        Formatted message string.
    """
    _notes = notes or []
    if _notes:
        return f"{action} {path}\n\n" + "\n\n".join(_notes)
    return f"{action} {path}"
