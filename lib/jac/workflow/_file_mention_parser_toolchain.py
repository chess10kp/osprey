"""File mention parser — @path and @path:10-20 extraction from user input."""

from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class FileMention:
    raw_text: str
    file_path: str
    start_index: int
    end_index: int
    line_range: dict | None = None  # {"start": int, "end": int | None}


_FILE_MENTION_RE = re.compile(r"@([^\s:]+)(?::(\d+)(?:-(\d+))?)?")


def is_valid_file_path(file_path: str) -> bool:
    if not file_path or not file_path.strip():
        return False
    segments = file_path.replace("\\", "/").split("/")
    if ".." in segments:
        return False
    if file_path.startswith("/") or file_path.startswith("\\"):
        return False
    if re.match(r"^[a-zA-Z]:[/\\]", file_path):
        return False
    if "\0" in file_path:
        return False
    return True


def parse_line_range(range_str: str) -> dict | None:
    if not range_str:
        return None
    parts = range_str.split("-")
    if len(parts) == 1:
        line = int(parts[0]) if parts[0].isdigit() else None
        if line is None or line <= 0:
            return None
        return {"start": line}
    if len(parts) == 2:
        start = int(parts[0]) if parts[0].isdigit() else None
        end = int(parts[1]) if parts[1].isdigit() else None
        if start is None or end is None or start <= 0 or end < start:
            return None
        return {"start": start, "end": end}
    return None


def parse_file_mentions(input_text: str) -> list[FileMention]:
    mentions: list[FileMention] = []
    for match in _FILE_MENTION_RE.finditer(input_text):
        raw_text = match.group(0)
        file_path = match.group(1)
        line_start = match.group(2)
        line_end = match.group(3)

        if not is_valid_file_path(file_path):
            continue

        mention = FileMention(
            raw_text=raw_text,
            file_path=file_path,
            start_index=match.start(),
            end_index=match.end(),
        )

        if line_start:
            start = int(line_start)
            end = int(line_end) if line_end else None
            if start > 0 and (end is None or end >= start):
                mention.line_range = {"start": start, "end": end}

        mentions.append(mention)

    return mentions


def parse_mention_token(raw: str) -> dict:
    """Parse a mention token (no leading @) into path + optional line range."""
    colon = raw.rfind(":")
    if colon <= 0:
        return {"path": raw}

    path_part = raw[:colon]
    range_part = raw[colon + 1 :]

    if not re.match(r"^\d+(-\d+)?$", range_part):
        return {"path": raw}

    rng = parse_line_range(range_part)
    if not rng:
        return {"path": raw}

    return {
        "path": path_part,
        "startLine": rng["start"],
        "endLine": rng.get("end", rng["start"]),
    }


def get_current_file_mention(
    input_text: str, cursor_position: int | None = None
) -> dict | None:
    """Active @mention at cursor for autocomplete."""
    pos = cursor_position if cursor_position is not None else len(input_text)

    start = -1
    for i in range(pos - 1, -1, -1):
        ch = input_text[i]
        if ch == "@":
            start = i
            break
        if ch in (" ", "\t", "\n"):
            break
    if start < 0:
        return None

    end = pos
    for i in range(pos, len(input_text)):
        ch = input_text[i]
        if ch in (" ", "\t", "\n", "@"):
            break
        end = i + 1

    full = input_text[start + 1 : end]
    range_match = re.match(r"^(.+?)(:\d+(?:-\d*)?)$", full)
    mention = range_match.group(1) if range_match else full
    range_suffix = range_match.group(2) if range_match else ""

    return {"mention": mention, "start": start, "end": end, "rangeSuffix": range_suffix}
