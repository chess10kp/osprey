"""Frontmatter parser — YAML-like --- delimited metadata extraction from markdown."""

from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class ParsedFrontmatter:
    frontmatter: dict[str, str | list[str]] = field(default_factory=dict)
    body: str = ""


def _parse_scalar(value: str) -> str | list[str]:
    trimmed = value.strip()
    if not trimmed:
        return ""

    if (trimmed.startswith('"') and trimmed.endswith('"')) or (
        trimmed.startswith("'") and trimmed.endswith("'")
    ):
        return trimmed[1:-1]

    if trimmed.startswith("[") and trimmed.endswith("]"):
        inner = trimmed[1:-1].strip()
        if not inner:
            return []
        return [
            part.strip().strip("\"'").strip("'\"")
            for part in inner.split(",")
            if part.strip()
        ]

    return trimmed


def parse_frontmatter(content: str) -> ParsedFrontmatter:
    frontmatter: dict[str, str | list[str]] = {}
    normalized = content.replace("\r\n", "\n")

    if not normalized.startswith("---"):
        return ParsedFrontmatter(frontmatter=frontmatter, body=normalized)

    end_index = normalized.find("\n---", 3)
    if end_index == -1:
        return ParsedFrontmatter(frontmatter=frontmatter, body=normalized)

    frontmatter_block = normalized[4:end_index]
    body = normalized[end_index + 4 :].strip()

    current_key: str | None = None
    list_items: list[str] = []

    def flush() -> None:
        nonlocal current_key, list_items
        if current_key and list_items:
            frontmatter[current_key] = list_items[:]
        list_items = []
        current_key = None

    for raw_line in frontmatter_block.split("\n"):
        line = raw_line.rstrip()
        list_match = re.match(r"^\s*-\s+(.*)$", line)
        if list_match and current_key:
            list_items.append(list_match.group(1).strip().strip("\"'").strip("'\""))
            continue

        flush()

        match = re.match(r"^([\w-]+):\s*(.*)$", line)
        if not match:
            continue

        key = match.group(1)
        value = match.group(2) or ""
        if not value.strip():
            current_key = key
            continue

        frontmatter[key] = _parse_scalar(value)

    flush()
    return ParsedFrontmatter(frontmatter=frontmatter, body=body)


def frontmatter_string(value: str | list[str] | None) -> str | None:
    if value is None:
        return None
    return ", ".join(value) if isinstance(value, list) else value


def frontmatter_string_list(value: str | list[str] | None) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value if v]
    return [part.strip() for part in value.split(",") if part.strip()]
