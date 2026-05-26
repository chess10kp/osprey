"""Tool output limit helpers (50 KiB UTF-8 safe truncation)."""

from __future__ import annotations

import json

MAX_TOOL_OUTPUT_BYTES = 50 * 1024
TRUNCATION_SUFFIX = "\n...[truncated at 50 KB]"


def truncate_tool_output(text: str, max_bytes: int = MAX_TOOL_OUTPUT_BYTES) -> str:
    if not text:
        return text

    encoded = text.encode("utf-8")
    if len(encoded) <= max_bytes:
        return text

    suffix_bytes = len(TRUNCATION_SUFFIX.encode("utf-8"))
    budget = max(0, max_bytes - suffix_bytes)

    cut = encoded[:budget]
    while cut:
        try:
            return cut.decode("utf-8") + TRUNCATION_SUFFIX
        except UnicodeDecodeError:
            cut = cut[:-1]

    return TRUNCATION_SUFFIX


def truncate_tool_payload(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return truncate_tool_output(value)
    if isinstance(value, dict) and "error" in value:
        return truncate_tool_output(str(value.get("error") or "Tool failed"))

    try:
        return truncate_tool_output(json.dumps(value, ensure_ascii=False))
    except Exception:
        return truncate_tool_output(str(value))
