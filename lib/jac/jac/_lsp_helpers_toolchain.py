"""Pure helper functions for LSP tool integration.

Ported from src/jac/lsp-tools.ts — only the pure/synchronous functions.
Async LSP client and service classes remain in TypeScript.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Optional, Sequence

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_GCC_DIAG_RE = re.compile(
    r"^(.+?):(\d+):(\d+):\s+(error|warning|info):\s+(.*)$", re.IGNORECASE
)
_IDENT_CHAR_RE = re.compile(r"[\w.]")
_REGEX_SPECIAL_RE = re.compile(r"([.*+?^${}()|\[\]\\])")


# ---------------------------------------------------------------------------
# Diagnostic dict shape:
#   {file: str, line: int, column?: int, severity: str, message: str,
#    code?: str|int, source?: str}
# Hover info dict shape:
#   {file: str, line: int, character: int, contents: list[str],
#    range?: {startLine, startChar, endLine, endChar}}
# Location dict shape:
#   {file: str, line: int, character?: int, endLine?: int,
#    endCharacter?: int, text?: str}
# ---------------------------------------------------------------------------


def parse_check_output(
    output: str,
    default_file: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Parse jac check output into a list of diagnostic dicts.

    Strips ANSI escape codes, then matches gcc-like format:
    ``file:line:col: severity: message``.

    Falls back to extracting the first ``error: ...`` line when no
    structured diagnostics are found and *default_file* is provided.
    """
    diagnostics: List[Dict[str, Any]] = []

    for raw in output.split("\n"):
        stripped = _ANSI_RE.sub("", raw).strip()
        if not stripped:
            continue

        m = _GCC_DIAG_RE.match(stripped)
        if m:
            diagnostics.append(
                {
                    "file": m.group(1),
                    "line": int(m.group(2)),
                    "column": int(m.group(3)),
                    "severity": m.group(4).lower(),
                    "message": m.group(5),
                }
            )

    if not diagnostics and default_file:
        err_match = re.search(r"error:\s*(.+)", output, re.IGNORECASE)
        if err_match:
            diagnostics.append(
                {
                    "file": default_file,
                    "line": 0,
                    "severity": "error",
                    "message": err_match.group(1).strip(),
                }
            )

    return diagnostics


def extract_symbol(line: str, character: int) -> str:
    """Extract the identifier/symbol at *character* position in *line*.

    Handles dotted names by returning only the last component
    (e.g. ``foo.bar.baz`` → ``baz``).
    """
    if not line or character < 0 or character >= len(line):
        return ""

    start = character
    while start > 0 and _IDENT_CHAR_RE.match(line[start - 1]):
        start -= 1

    end = character
    while end < len(line) and _IDENT_CHAR_RE.match(line[end]):
        end += 1

    if start == end:
        return ""

    full = line[start:end]
    parts = full.split(".")
    return parts[-1] if parts else full


def escape_regex(s: str) -> str:
    """Escape regex special characters in *s*."""
    return _REGEX_SPECIAL_RE.sub(r"\\\1", s)


def format_lsp_diagnostics(diagnostics: Sequence[Dict[str, Any]]) -> str:
    """Format a diagnostics list for display."""
    if not diagnostics:
        return "No diagnostics."

    lines: List[str] = []
    for d in diagnostics:
        col = f":{d['column']}" if d.get("column") else ""
        code = f" [{d['code']}]" if d.get("code") else ""
        src = f" ({d['source']})" if d.get("source") else ""
        lines.append(
            f"{d['file']}:{d['line']}{col} [{d['severity']}]{code}{src} {d['message']}"
        )
    return "\n".join(lines)


def format_hover_info(info: Dict[str, Any]) -> str:
    """Format hover info dict for display."""
    contents = info.get("contents", [])
    if isinstance(contents, list):
        return "\n".join(str(c) for c in contents)
    return str(contents)


def format_locations(
    locations: Sequence[Dict[str, Any]],
    label: str = "Results",
) -> str:
    """Format a locations list for display.

    Limits output to 20 entries and truncates long text lines.
    """
    if not locations:
        return f"No {label.lower()} found."

    lines: List[str] = []
    for loc in list(locations)[:20]:
        text = loc.get("text", "")
        if text:
            if len(text) > 100:
                text = text[:97] + "..."
            text = f": {text}"
        lines.append(f"{loc['file']}:{loc['line']}{text}")
    return "\n".join(lines)
