"""Session persistence for the agent harness, byte-compatible with the
legacy Pi runtime on-disk format (ported from src/session/session.ts +
src/session/session-index.ts).

Layout (verified against real files under .jackal/sessions):
- One transcript per session: `<cwd>/.jackal/sessions/<id>.json` holding a
  single JSON object (not JSONL) with exactly six top-level keys:
  sessionId, sessionName, cwd, createdAt, updatedAt, messages. The messages
  array holds OpenAI-shape message dicts ({role, content}). Files are
  written indent=2 with a trailing newline.
- Session ids are `sess_<epoch_milliseconds>` (digits only after the
  prefix). Same-millisecond collisions bump the millisecond by one so ids
  stay monotonic and pattern-valid.
- Timestamps are ISO 8601 UTC with milliseconds and a Z suffix.
- Index sidecar `<cwd>.jackal/sessions/index.json` is a JSON array of
  {id, name, cwd, updatedAt, messageCount} objects, also indent=2.
- Default session name is "new session".

Interoperability: every file this module writes is loadable by the legacy
runtime, and legacy-written transcripts plus indexes load here unchanged.
list_sessions reads index.json but merges in directory-scan entries when
the index is missing, stale, or corrupt, rebuilding it when needed.

Not ported (runtime-loop concerns): auto-save timers, compaction backups,
legacy latest.json migration, retention pruning.

Deviation from byte-compat: save_session accepts an optional `model` ref.
When non-empty it is stored as a seventh top-level key "model" so restore
can bring back model+transcript together. Legacy loaders ignore unknown
keys, so files remain loadable there; saves without a model stay
byte-identical to the six-key format.
"""

import os;
import json;
import time;
import re;
import datetime;

glob _last_id_ms: int = 0,
     _SESSION_ID_PATTERN: str = r"^sess_[0-9]+$",
     _DEFAULT_NAME: str = "new session",
     _INDEX_NAME: str = "index.json",
     _LEGACY_INDEX_NAME: str = "latest.json",
     _TRANSCRIPT_SUFFIX: str = ".json";


# ── Checker shims ─────────────────────────────────────────────────────────


"""Checker shims: os.path.abspath/dirname demand PathLike under native
checking when plain str values flow in; route through any-typed aliases
(same pattern as compaction.jac / extensions.jac)."""
def _path_abspath(p: str) -> str {
    fn: any = os.path.abspath;
    return str(fn(p));
}


def _path_dirname(p: str) -> str {
    fn: any = os.path.dirname;
    return str(fn(p));
}


def _sessions_dir(cwd: str) -> str {
    return os.path.join(cwd, ".jackal", "sessions");
}


def _session_path(cwd: str, session_id: str) -> str {
    return os.path.join(_sessions_dir(cwd), session_id + _TRANSCRIPT_SUFFIX);
}


def _index_path(cwd: str) -> str {
    return os.path.join(_sessions_dir(cwd), _INDEX_NAME);
}


def is_valid_session_id(session_id: str) -> bool {
    return isinstance(session_id, str) and re.match(_SESSION_ID_PATTERN, session_id) is not None;
}


"""Monotonic epoch milliseconds: same-millisecond callers get ms + 1."""
def _next_epoch_ms() -> int {
    ms = int(time.time() * 1000);
    if ms <= _last_id_ms {
        ms = _last_id_ms + 1;
    }
    _last_id_ms = ms;
    return ms;
}


"""Fresh legacy-format id: sess_<epoch_milliseconds>, digits only."""
def new_session_id() -> str {
    return "sess_" + str(_next_epoch_ms());
}


def _iso_from_ms(ms: int) -> str {
    (secs, msec) = divmod(ms, 1000);
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(secs)) + f".{msec:03d}Z";
}


def _now_iso() -> str {
    return _iso_from_ms(_next_epoch_ms());
}


"""Parse a JSON file; None when missing or corrupt."""
def _read_json(path: str) -> any {
    fh = None;
    try {
        fh = open(path, "r");
        raw = json.load(fh);
    } except (OSError, ValueError) {
        return None;
    } finally {
        if fh is not None {
            fh.close();
        }
    }
    return raw;
}


"""Write pretty JSON (indent=2 + trailing newline); False on I/O failure."""
def _write_json(path: str, data: any) -> bool {
    fh = None;
    try {
        fh = open(path, "w");
        json.dump(data, fh, indent=2);
        fh.write("\n");
    } except OSError {
        return False;
    } finally {
        if fh is not None {
            fh.close();
        }
    }
    return True;
}


"""Legacy SessionRecord shape check (mirrors isSessionRecord upstream)."""
def _is_record(rec: any) -> bool {
    return (
        isinstance(rec, dict)
        and isinstance(rec.get("sessionId"), str)
        and isinstance(rec.get("sessionName"), str)
        and isinstance(rec.get("cwd"), str)
        and isinstance(rec.get("updatedAt"), str)
        and isinstance(rec.get("messages"), list)
    );
}


"""Legacy SessionIndexEntry shape check (mirrors isIndexEntry upstream)."""
def _is_index_entry(item: any) -> bool {
    return (
        isinstance(item, dict)
        and isinstance(item.get("id"), str)
        and isinstance(item.get("name"), str)
        and isinstance(item.get("cwd"), str)
        and isinstance(item.get("updatedAt"), str)
        and isinstance(item.get("messageCount"), (int, float))
    );
}


def _entry_sort_key(rec: dict) -> str {
    return str(rec.get("updatedAt", ""));
}


"""Order entries newest-updated first (stable on ties)."""
def _newest_first(entries: list) -> list {
    return sorted(entries, key=_entry_sort_key, reverse=True);
}


"""Validated index entries whose transcript still exists; second value is
False when index.json was missing or corrupt."""
def _read_index(cwd: str) -> tuple[list, bool] {
    raw = _read_json(_index_path(cwd));
    valid: list = [];
    if not isinstance(raw, list) {
        return (valid, False);
    }
    for item in raw {
        if not _is_index_entry(item) or not is_valid_session_id(str(item["id"])) {
            continue;
        }
        sid = str(item["id"]);
        if not os.path.exists(_session_path(cwd, sid)) {
            continue;
        }
        valid.append({
            "id": sid,
            "name": str(item["name"]),
            "cwd": str(item["cwd"]),
            "updatedAt": str(item["updatedAt"]),
            "messageCount": int(item["messageCount"]),
        });
    }
    return (valid, True);
}


def _write_index(cwd: str, entries: list) -> bool {
    sdir = _sessions_dir(cwd);
    try {
        os.makedirs(sdir, exist_ok=True);
    } except OSError {
        return False;
    }
    return _write_json(_index_path(cwd), entries);
}


"""Replace or append one entry in the index, preserving the others."""
def _upsert_index_entry(cwd: str, rec: dict) -> bool {
    (entries, _ok) = _read_index(cwd);
    kept: list = [];
    for existing in entries {
        if str(existing["id"]) != str(rec["id"]) {
            kept.append(existing);
        }
    }
    kept.append({
        "id": str(rec["id"]),
        "name": str(rec["name"]),
        "cwd": str(rec["cwd"]),
        "updatedAt": str(rec["updatedAt"]),
        "messageCount": int(rec["messageCount"]),
    });
    return _write_index(cwd, kept);
}


"""Scan *.json transcripts (excluding sidecars), skipping corrupt ones.

Returns legacy-shaped index entries; used to merge into listings and to
rebuild a missing or corrupt index.
"""
def _scan_directory(cwd: str) -> list {
    found: list = [];
    sdir = _sessions_dir(cwd);
    if not os.path.isdir(sdir) {
        return found;
    }
    try {
        names = os.listdir(sdir);
    } except OSError {
        return found;
    }
    for name in names {
        if not name.endswith(_TRANSCRIPT_SUFFIX) or name == _INDEX_NAME or name == _LEGACY_INDEX_NAME {
            continue;
        }
        sid = name[:-len(_TRANSCRIPT_SUFFIX)];
        if not is_valid_session_id(sid) {
            continue;
        }
        rec = _read_json(os.path.join(sdir, name));
        if not isinstance(rec, dict) or str(rec.get("sessionId", "")) != sid {
            continue;
        }
        messages = rec.get("messages");
        count = len(messages) if isinstance(messages, list) else 0;
        updated = rec.get("updatedAt");
        found.append({
            "id": sid,
            "name": str(rec.get("sessionName", "")),
            "cwd": str(rec.get("cwd", cwd)),
            "updatedAt": updated if isinstance(updated, str) else "",
            "messageCount": count,
        });
    }
    return found;
}


"""Persist one conversation as a legacy-format transcript record.

`history` is the caller-owned list of OpenAI-shape message dicts; it is
stored verbatim under `messages`. Returns metadata:
{id, name, path, created, updated, messageCount}. Re-saving an existing
`session_id` preserves its original createdAt stamp (and prior name when no
new name is given).
"""
def save_session(
    cwd: str, history: list, name: str = "", session_id: str = "",
    model: str = "",
) -> dict {
    sid = session_id if session_id else new_session_id();
    if not is_valid_session_id(sid) {
        raise ValueError("invalid session id: " + str(sid));
    }
    sdir = _sessions_dir(cwd);
    try {
        os.makedirs(sdir, exist_ok=True);
    } except OSError as exc {
        raise ValueError("cannot create sessions dir: " + str(exc));
    }
    path = _session_path(cwd, sid);

    created = _now_iso();
    prior_name = "";
    prior_model = "";
    existing = _read_json(path);
    if _is_record(existing) {
        prior_created = existing.get("createdAt");
        if isinstance(prior_created, str) and prior_created {
            created = prior_created;
        }
        recorded = existing.get("sessionName");
        if isinstance(recorded, str) {
            prior_name = recorded;
        }
        prior_rec_model = existing.get("model");
        if isinstance(prior_rec_model, str) {
            prior_model = prior_rec_model;
        }
    }

    trimmed = name.strip();
    if trimmed {
        final_name: str = trimmed;
    } elif prior_name {
        final_name = prior_name;
    } else {
        final_name = _DEFAULT_NAME;
    }

    updated = _now_iso();
    record = {
        "sessionId": sid,
        "sessionName": final_name,
        "cwd": cwd,
        "createdAt": created,
        "updatedAt": updated,
        "messages": history,
    };
    final_model = model.strip() if isinstance(model, str) else "";
    if not final_model {
        final_model = prior_model;
    }
    if final_model {
        # Optional seventh key — see module docstring deviation note.
        record["model"] = final_model;
    }
    if not _write_json(path, record) {
        raise ValueError("cannot write transcript: " + path);
    }
    _upsert_index_entry(cwd, {
        "id": sid,
        "name": final_name,
        "cwd": cwd,
        "updatedAt": updated,
        "messageCount": len(history),
    });
    return {
        "id": sid,
        "name": final_name,
        "path": path,
        "created": created,
        "updated": updated,
        "messageCount": len(history),
        "model": final_model,
    };
}


"""Full transcript record for one session, or None when unknown/corrupt.
Used by restore flows that need model + metadata, not just messages."""
def get_session_record(cwd: str, session_id: str) -> dict | None {
    if not is_valid_session_id(session_id) {
        return None;
    }
    rec = _read_json(_session_path(cwd, session_id));
    if not _is_record(rec) {
        return None;
    }
    return rec;
}


"""Messages for one session; [] when the id is unknown or the transcript
is missing/corrupt."""
def load_session(cwd: str, session_id: str) -> list {
    if not is_valid_session_id(session_id) {
        return [];
    }
    rec = _read_json(_session_path(cwd, session_id));
    if not _is_record(rec) {
        return [];
    }
    messages = rec.get("messages");
    if not isinstance(messages, list) {
        return [];
    }
    return messages;
}


"""All sessions for a project, newest-updated first.

Merges index.json entries with a directory scan so sessions missing from a
missing/stale/corrupt index still appear; a missing or corrupt index is
rebuilt from disk when anything is found.
"""
def list_sessions(cwd: str) -> list {
    sdir = _sessions_dir(cwd);
    if not os.path.isdir(sdir) {
        return [];
    }
    (indexed, index_ok) = _read_index(cwd);
    merged: list = [];
    seen: set[str] = set();
    for item in indexed {
        merged.append(item);
        seen.add(str(item["id"]));
    }
    for item in _scan_directory(cwd) {
        if str(item["id"]) not in seen {
            merged.append(item);
        }
    }
    ordered = _newest_first(merged);
    if not index_ok and ordered {
        _write_index(cwd, ordered);
    }
    return ordered;
}


"""Set the session name in BOTH the transcript and the index.

True on success; False for blank names or unknown/invalid ids. Bumps
updatedAt like the legacy rename-and-flush flow does.
"""
def rename_session(cwd: str, session_id: str, name: str) -> bool {
    trimmed = name.strip();
    if not trimmed or not is_valid_session_id(session_id) {
        return False;
    }
    rec = _read_json(_session_path(cwd, session_id));
    if not _is_record(rec) or str(rec.get("sessionId", "")) != session_id {
        return False;
    }
    messages = rec.get("messages");
    count = len(messages) if isinstance(messages, list) else 0;
    prior_cwd = rec.get("cwd");
    record_cwd = prior_cwd if isinstance(prior_cwd, str) and prior_cwd else cwd;
    prior_created = rec.get("createdAt");
    created = prior_created if isinstance(prior_created, str) and prior_created else _now_iso();

    updated = _now_iso();
    renamed = {
        "sessionId": session_id,
        "sessionName": trimmed,
        "cwd": record_cwd,
        "createdAt": created,
        "updatedAt": updated,
        "messages": messages if isinstance(messages, list) else [],
    };
    if not _write_json(_session_path(cwd, session_id), renamed) {
        return False;
    }
    _upsert_index_entry(cwd, {
        "id": session_id,
        "name": trimmed,
        "cwd": record_cwd,
        "updatedAt": updated,
        "messageCount": count,
    });
    return True;
}


"""Remove the transcript and its index entry.

True when the session existed, False otherwise (including invalid ids such
as path-traversal attempts).
"""
def delete_session(cwd: str, session_id: str) -> bool {
    if not is_valid_session_id(session_id) {
        return False;
    }
    path = _session_path(cwd, session_id);
    existed = os.path.exists(path);
    if existed {
        try {
            os.remove(path);
        } except OSError {
            return False;
        }
    }
    (entries, _ok) = _read_index(cwd);
    remaining: list = [];
    removed_entry = False;
    for item in entries {
        if str(item["id"]) == session_id {
            removed_entry = True;
        } else {
            remaining.append(item);
        }
    }
    if existed or removed_entry {
        _write_index(cwd, remaining);
    }
    return existed or removed_entry;
}
