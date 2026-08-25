"""User-message context expansion for the agent harness (ported from
src/workflow/file-mention-parser.ts + src/workflow/context-input.ts, with
parity against lib/jac/workflow/_file_mention_parser_toolchain.py).

Two layers:

- Mention parsing: extract `@path` and `@path:10-20` tokens from user text,
  validate paths (reject absolute, drive-letter, traversal, NUL), parse
  optional line ranges (reversed or zero/negative ranges yield no range),
  resolve a single token into path + start/end line, and locate the active
  `@mention` under the cursor for autocomplete.
- Expansion: rewrite user text before sending to the agent. A leading
  `!cmd` runs the command through `bash -lc` in the project cwd and wraps
  its output in a <command_output> block. Otherwise each unique mention's
  file slice is attached as a fenced <file path="..."> block; unreadable
  files become self-closing error blocks instead of aborting the turn.
  Slices larger than _MAX_FILE_CHARS are truncated with a marker; totals
  over _TOKEN_WARN_CHARS prepend an approximate-token warning header.

Semantics preserved from the legacy sources: empty input passes through
untouched, text without any mention/command passes through untouched, and
out-of-bounds line ranges clamp to the file (empty slice past EOF rather
than an error).
"""

import os;
import re;
import subprocess;

glob _FILE_MENTION_PATTERN: str = r"@([^\s:]+)(?::(\d+)(?:-(\d+))?)?",
     _MENTION_RANGE_PATTERN: str = r"^\d+(-\d+)?$",
     _CURSOR_RANGE_FULL: str = r"^(.+?)(:\d+(?:-\d*)?)$",
     _WINDOWS_DRIVE_PATTERN: str = r"^[a-zA-Z]:[/\\]",
     _MAX_FILE_CHARS: int = 80000,
     _TOKEN_WARN_CHARS: int = 40000,
     _COMMAND_TIMEOUT_SECS: float = 60.0;


"""Checker shim: os.path.abspath/normpath stubs require PathLike, so route
plain str values through any-typed aliases (same pattern as checkpoints.jac)."""
def _path_abspath(p: str) -> str {
    fn: any = os.path.abspath;
    return str(fn(p));
}


def _path_normpath(p: str) -> str {
    fn: any = os.path.normpath;
    return str(fn(p));
}


"""Reject absolute, drive-letter, traversal, and NUL paths."""
def is_valid_file_path(file_path: str) -> bool {
    if not isinstance(file_path, str) or not file_path.strip() {
        return False;
    }
    segments = file_path.replace("\\", "/").split("/");
    if ".." in segments {
        return False;
    }
    if file_path.startswith("/") or file_path.startswith("\\") {
        return False;
    }
    if re.match(_WINDOWS_DRIVE_PATTERN, file_path) is not None {
        return False;
    }
    if "\0" in file_path {
        return False;
    }
    return True;
}


"""{"start"} or {"start", "end"} for a `10` / `10-20` string; None when
malformed, zero, negative, or reversed."""
def parse_line_range(range_str: str) -> dict | None {
    if not range_str {
        return None;
    }
    parts = range_str.split("-");
    if len(parts) == 1 {
        if not parts[0].isdigit() {
            return None;
        }
        line = int(parts[0]);
        if line <= 0 {
            return None;
        }
        return {"start": line};
    }
    if len(parts) == 2 {
        if not parts[0].isdigit() or not parts[1].isdigit() {
            return None;
        }
        start = int(parts[0]);
        end = int(parts[1]);
        if start <= 0 or end < start {
            return None;
        }
        return {"start": start, "end": end};
    }
    return None;
}


"""All `@path` / `@path:10-20` mentions in input, in order of appearance.

Each mention is {raw_text, file_path, start_index, end_index, line_range}
where line_range is None or {start, end?}. Invalid paths are skipped; a
syntactically present but rejected range leaves line_range None (whole
file)."""
def parse_file_mentions(input_text: str) -> list {
    mentions: list = [];
    for match in re.finditer(_FILE_MENTION_PATTERN, input_text) {
        file_path = str(match.group(1));
        if not is_valid_file_path(file_path) {
            continue;
        }
        line_start = match.group(2);
        line_end = match.group(3);
        mention: dict = {
            "raw_text": match.group(0),
            "file_path": file_path,
            "start_index": match.start(),
            "end_index": match.end(),
            "line_range": None,
        };
        if line_start {
            start = int(line_start);
            end = int(line_end) if line_end else None;
            if start > 0 and (end is None or end >= start) {
                mention["line_range"] = {"start": start, "end": end};
            }
        }
        mentions.append(mention);
    }
    return mentions;
}


"""Path + startLine/endLine for a mention token without the leading `@`.

A trailing `:<digits>[-<digits>]` is consumed as the range; anything else
(non-digit suffix, malformed or reversed range, no colon) returns the raw
token as the path unchanged."""
def parse_mention_token(raw: str) -> dict {
    colon = raw.rfind(":");
    if colon <= 0 {
        return {"path": raw};
    }
    path_part = raw[:colon];
    range_part = raw[colon + 1:];
    if re.match(_MENTION_RANGE_PATTERN, range_part) is None {
        return {"path": raw};
    }
    rng = parse_line_range(range_part);
    if rng is None {
        return {"path": raw};
    }
    return {
        "path": path_part,
        "startLine": rng["start"],
        "endLine": rng.get("end", rng["start"]),
    };
}


"""Active `@mention` spanning the cursor position, for autocomplete.

Returns {mention, start, end, rangeSuffix} or None when the cursor is not
inside a mention. Scanning stops at whitespace backwards and at
whitespace or `@` forwards."""
def get_current_file_mention(input_text: str, cursor_position: int = -1) -> dict | None {
    pos = cursor_position if cursor_position >= 0 else len(input_text);

    start = -1;
    idx = pos - 1;
    while idx >= 0 {
        ch = input_text[idx];
        if ch == "@" {
            start = idx;
            break;
        }
        if ch == " " or ch == "\t" or ch == "\n" {
            break;
        }
        idx -= 1;
    }
    if start < 0 {
        return None;
    }

    end = pos;
    idx = pos;
    while idx < len(input_text) {
        ch = input_text[idx];
        if ch == " " or ch == "\t" or ch == "\n" or ch == "@" {
            break;
        }
        end = idx + 1;
        idx += 1;
    }

    full = input_text[start + 1:end];
    range_match = re.match(_CURSOR_RANGE_FULL, full);
    if range_match is not None {
        mention = str(range_match.group(1));
        range_suffix = str(range_match.group(2));
    } else {
        mention = full;
        range_suffix = "";
    }
    return {"mention": mention, "start": start, "end": end, "rangeSuffix": range_suffix};
}


"""Resolve input_path inside cwd; ValueError when it escapes the root."""
def _safe_resolve(cwd: str, input_path: str) -> str {
    abs_path = _path_normpath(_path_abspath(os.path.join(cwd, input_path)));
    root_dir = _path_normpath(_path_abspath(cwd) + "/");
    if not (abs_path + "/").startswith(root_dir) and abs_path != root_dir {
        raise ValueError("Path escapes cwd: " + input_path);
    }
    return abs_path;
}


"""Read one file slice and render it as a fenced <file> context block.

`mention` is a token without the leading `@`; `line_range` (when given)
overrides any range embedded in the token. Returns (block, char_count).
Raises OSError/ValueError for unreadable or escaping paths."""
def _load_file_slice(cwd: str, mention: str, line_range: any = None) -> tuple[str, int] {
    token_start: any = None;
    token_end: any = None;
    if line_range is not None {
        token_start = line_range.get("start");
        token_end = line_range.get("end");
        if token_end is None {
            token_end = token_start;
        }
        file_path = mention;
    } else {
        parsed = parse_mention_token(mention);
        file_path = str(parsed.get("path", mention));
        token_start = parsed.get("startLine");
        token_end = parsed.get("endLine");
    }

    abs_path = _safe_resolve(cwd, file_path);
    fh = open(abs_path, "r");
    try {
        content = fh.read();
    } finally {
        fh.close();
    }

    text = content;
    label = file_path;
    if isinstance(token_start, int) {
        lines = content.split("\n");
        lo = max(1, token_start) - 1;
        hi = min(len(lines), token_end if isinstance(token_end, int) else token_start);
        text = "\n".join(lines[lo:hi]);
        suffix = "";
        if isinstance(token_end, int) and token_end != token_start {
            suffix = "-" + str(token_end);
        }
        label = file_path + ":" + str(token_start) + suffix;
    }

    if len(text) > _MAX_FILE_CHARS {
        text = text[:_MAX_FILE_CHARS] + "\n...[truncated at " + str(_MAX_FILE_CHARS) + " chars]";
    }

    block = '<file path="' + label + '">\n```\n' + text + "\n```\n</file>";
    return (block, len(text));
}


"""Run `command` via `bash -lc` in cwd; collect stdout/stderr plus exit
status into a deterministic report string. Hard timeout of 60 seconds;
spawn failures and timeouts degrade to messages instead of raising."""
def _run_inline_command(cwd: str, command: str) -> str {
    try {
        proc = subprocess.run(
            ["bash", "-lc", command],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=_COMMAND_TIMEOUT_SECS,
        );
    } except subprocess.TimeoutExpired {
        return "Command timed out after 60 seconds";
    } except OSError as exc {
        return "Command failed: " + str(exc);
    }
    parts: list = [];
    if proc.stdout {
        parts.append("stdout:\n" + proc.stdout);
    }
    if proc.stderr {
        parts.append("stderr:\n" + proc.stderr);
    }
    parts.append("exit=" + str(proc.returncode));
    return "\n".join(parts)[:_MAX_FILE_CHARS];
}


"""Expand `!cmd` prefixes and `@path` mentions in user text into prompt
context blocks.

Empty input, a bare `!`, and text with neither a command nor a valid
mention are returned verbatim. Mention results are appended under an
"Attached context:" header (deduped by raw token, error-tolerant per
file); large attachments add an approximate-token warning above the
original text."""
def expand_context_input(cwd: str, text: str) -> str {
    trimmed = text.strip();
    if not trimmed {
        return text;
    }

    if trimmed.startswith("!") {
        command = trimmed[1:].strip();
        if not command {
            return text;
        }
        output = _run_inline_command(cwd, command);
        return "\n".join([
            "User ran inline command: `" + command + "`",
            "<command_output>",
            output,
            "</command_output>",
            "Continue based on the command output above.",
        ]);
    }

    mentions = parse_file_mentions(trimmed);
    if not mentions {
        return text;
    }

    blocks: list = [];
    seen: set[str] = set();
    total_chars = 0;
    for mention in mentions {
        raw = str(mention["raw_text"]);
        if raw in seen {
            continue;
        }
        seen.add(raw);
        file_path = str(mention["file_path"]);
        try {
            (block, chars) = _load_file_slice(cwd, file_path, mention["line_range"]);
            blocks.append(block);
            total_chars += chars;
        } except (OSError, ValueError) as exc {
            blocks.append('<file path="' + file_path + '" error="' + str(exc) + '" />');
        }
    }

    header = trimmed;
    if total_chars >= _TOKEN_WARN_CHARS {
        header = (
            "[Warning: attached files ~" + str(total_chars // 4) + " tokens]\n"
            + trimmed
        );
    }
    return header + "\n\nAttached context:\n" + "\n".join(blocks);
}
