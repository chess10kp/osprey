"""Session export and retention helpers."""

import os;
import time;
import datetime;
import from .sessions_core {
    _path_abspath,
    _path_dirname,
    _sessions_dir,
    _session_path,
    _read_json,
    _write_json,
    _write_index,
    get_session_record,
    list_sessions,
}

"""Epoch seconds for a legacy ISO-8601 Z timestamp, or None if unparseable."""
def _iso_to_epoch(stamp: str) -> float | None {
    txt = stamp.strip();
    if not txt {
        return None;
    }
    if txt.endswith("Z") {
        txt = txt[:-1] + "+00:00";
    }
    try {
        dt = datetime.datetime.fromisoformat(txt);
    } except ValueError {
        return None;
    }
    try {
        return dt.timestamp();
    } except (OSError, OverflowError) {
        return None;
    }
}


"""Delete sessions beyond the retention policy; returns the count pruned.

max_count: keep only the N most recently updated sessions (0 disables).
retention_days: also delete any session whose updatedAt is older than N
    days (0 disables). Both zero means pruning is disabled entirely.

Mirrors legacy pruneSessions in src/session/session-index.ts: entries are
walked newest-updated first, a transcript is removed when it is past the
count limit or past the age limit, and index.json is rewritten once with
the survivors so it stays consistent with the directory."""
def prune_sessions(cwd: str, max_count: int = 0, retention_days: int = 0) -> int {
    if max_count <= 0 and retention_days <= 0 {
        return 0;
    }
    if not os.path.isdir(_sessions_dir(cwd)) {
        return 0;
    }
    entries = list_sessions(cwd);
    if not entries {
        return 0;
    }
    now = time.time();
    max_age_secs = retention_days * 24 * 60 * 60 if retention_days > 0 else 0;
    kept: list = [];
    pruned = 0;
    idx = 0;
    for item in entries {
        stale = False;
        if max_age_secs > 0 {
            ts = _iso_to_epoch(str(item.get("updatedAt", "")));
            if ts is not None and (now - ts) > max_age_secs {
                stale = True;
            }
        }
        over_count = max_count > 0 and idx >= max_count;
        if stale or over_count {
            sid = str(item["id"]);
            try {
                os.remove(_session_path(cwd, sid));
            } except OSError {}
            pruned += 1;
        } else {
            kept.append(item);
        }
        idx += 1;
    }
    if pruned > 0 {
        _write_index(cwd, kept);
    }
    return pruned;
}


"""Id of the most recently updated session, or None when there are none."""
def latest_session_id(cwd: str) -> str | None {
    entries = list_sessions(cwd);
    if not entries {
        return None;
    }
    return str(entries[0].get("id"));
}


"""Export one session transcript as readable Markdown.

Writes to `path` (parent dirs created). Tool messages render as fenced
blocks under their preceding call. True on success; False for unknown ids,
unwritable targets, or corrupt transcripts."""
def export_session(cwd: str, session_id: str, path: str) -> bool {
    rec: dict | None = get_session_record(cwd, session_id);
    if rec is None {
        return False;
    }
    messages = rec.get("messages");
    if not isinstance(messages, list) {
        return False;
    }
    lines: list[str] = [];
    name = str(rec.get("sessionName", "session"));
    lines.append("# " + name);
    lines.append("");
    lines.append("- session: " + session_id);
    lines.append("- updated: " + str(rec.get("updatedAt", "")));
    rec_model = rec.get("model");
    if isinstance(rec_model, str) and rec_model {
        lines.append("- model: " + rec_model);
    }
    lines.append("");
    for msg in messages {
        if not isinstance(msg, dict) {
            continue;
        }
        role = str(msg.get("role", ""));
        content = str(msg.get("content", "") or "");
        if role == "user" {
            lines.append("## user");
            lines.append("");
            lines.append(content);
            lines.append("");
        } elif role == "assistant" {
            calls = msg.get("tool_calls");
            if isinstance(calls, list) and calls {
                for call in calls {
                    if not isinstance(call, dict) { continue; }
                    fn: any = call.get("function", {});
                    if not isinstance(fn, dict) { continue; }
                    lines.append(
                        "**tool call: " + str(fn.get("name", "")) + "**"
                    );
                    lines.append("");
                    lines.append("```json");
                    lines.append(str(fn.get("arguments", "{}")));
                    lines.append("```");
                    lines.append("");
                }
            }
            if content {
                lines.append("## assistant");
                lines.append("");
                lines.append(content);
                lines.append("");
            }
        } elif role == "tool" {
            lines.append("### tool result");
            lines.append("");
            lines.append("```");
            lines.append(content);
            lines.append("```");
            lines.append("");
        } elif role == "system" {
            # System prompts are runtime state, not transcript.
            continue;
        }
    }
    parent = _path_dirname(_path_abspath(path));
    try {
        os.makedirs(parent, exist_ok=True);
        with open(path, "w") as fh {
            fh.write("\n".join(lines).rstrip("\n") + "\n");
        }
    } except OSError {
        return False;
    }
    return True;
}
