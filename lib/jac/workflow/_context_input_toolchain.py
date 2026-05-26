"""Context input expansion — @file mentions and !command prefixes."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

MAX_FILE_CHARS = 80_000
TOKEN_WARN_CHARS = 40_000


def _safe_resolve(cwd: str, input_path: str) -> str:
    abs_path = os.path.normpath(
        input_path if os.path.isabs(input_path) else os.path.join(cwd, input_path)
    )
    root = os.path.normpath(os.path.join(cwd, ""))
    if not (abs_path + os.sep).startswith(root) and abs_path != os.path.normpath(cwd):
        raise ValueError(f"Path escapes cwd: {input_path}")
    return abs_path


def _parse_mention_token(token: str) -> dict:
    """Parse @path or @path:line or @path:start-end."""
    # Delegate to file_mention_parser for robustness
    from _file_mention_parser_toolchain import parse_mention_token as _pmt  # noqa: C0415

    return _pmt(token)


def load_file_slice(
    cwd: str,
    mention: str,
    line_range: dict | None = None,
) -> dict:
    """Return {block, chars} for a file mention."""
    if line_range:
        parsed = {
            "path": mention,
            "startLine": line_range.get("start"),
            "endLine": line_range.get("end", line_range.get("start")),
        }
    else:
        parsed = _parse_mention_token(mention)

    file_path = parsed.get("path", mention)
    start_line = parsed.get("startLine")
    end_line = parsed.get("endLine")

    abs_path = _safe_resolve(cwd, file_path)
    content = Path(abs_path).read_text(encoding="utf-8")
    text = content
    label = file_path

    if start_line is not None:
        lines = content.split("\n")
        start = max(1, start_line) - 1
        end = min(len(lines), end_line or start_line)
        text = "\n".join(lines[start:end])
        end_str = f"-{end_line}" if end_line and end_line != start_line else ""
        label = f"{file_path}:{start_line}{end_str}"

    if len(text) > MAX_FILE_CHARS:
        text = text[:MAX_FILE_CHARS] + f"\n...[truncated at {MAX_FILE_CHARS} chars]"

    block = f'<file path="{label}">\n```\n{text}\n```\n</file>'
    return {"block": block, "chars": len(text)}


def run_inline_command(cwd: str, command: str) -> str:
    """Run a shell command and return combined stdout/stderr."""
    try:
        result = subprocess.run(
            ["bash", "-lc", command],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        parts = []
        if result.stdout:
            parts.append(f"stdout:\n{result.stdout}")
        if result.stderr:
            parts.append(f"stderr:\n{result.stderr}")
        parts.append(f"exit={result.returncode}")
        combined = "\n".join(parts)
    except subprocess.TimeoutExpired:
        combined = "Command timed out after 60 seconds"
    except Exception as exc:
        combined = f"Command failed: {exc}"

    return combined[:MAX_FILE_CHARS]


# Regex for @file mentions
_MENTION_RE = re.compile(r"@([\w./\-](?:[\w./\-:]*[\w./\-])?)")


def parse_file_mentions(text: str) -> list[dict]:
    """Extract @file mentions from text."""
    from _file_mention_parser_toolchain import parse_file_mentions as _pfm  # noqa: C0415

    return _pfm(text)


def expand_context_input_sync(cwd: str, text: str) -> dict:
    """Expand !command and @file mentions. Returns {result, error}."""
    trimmed = text.strip()
    if not trimmed:
        return {"result": text}

    # !command expansion
    if trimmed.startswith("!"):
        command = trimmed[1:].strip()
        if not command:
            return {"result": text}
        output = run_inline_command(cwd, command)
        result = "\n".join([
            f"User ran inline command: `{command}`",
            "<command_output>",
            output,
            "</command_output>",
            "Continue based on the command output above.",
        ])
        return {"result": result}

    # @file expansion
    mentions = parse_file_mentions(trimmed)
    if not mentions:
        return {"result": text}

    blocks: list[str] = []
    total_chars = 0
    seen: set[str] = set()

    for mention in mentions:
        key = mention.raw_text
        if key in seen:
            continue
        seen.add(key)
        try:
            file_path = mention.file_path
            lr = mention.line_range
            sl = load_file_slice(cwd, file_path, lr)
            blocks.append(sl["block"])
            total_chars += sl["chars"]
        except Exception as exc:
            blocks.append(f'<file path="{mention.file_path}" error="{exc}" />')

    header = trimmed
    if total_chars >= TOKEN_WARN_CHARS:
        header = f"[Warning: attached files ~{total_chars // 4} tokens]\n{trimmed}"

    result = header + "\n\nAttached context:\n" + "\n".join(blocks)
    return {"result": result}
