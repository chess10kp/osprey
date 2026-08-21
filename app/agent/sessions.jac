"""Session persistence for the agent harness (essentials ported from
src/session/session.ts + src/session/session-index.ts).

Layout mirrors the legacy reference: JSONL transcripts under
`<cwd>/.jackal/sessions/<id>.jsonl` (one OpenAI-shape message dict per line)
plus an `index.json` sidecar holding lightweight metadata (id, title,
created/updated stamps, turn count). Interoperates with agent/session.jac's
caller-owned `history: list` of {"role": ..., "content": ...} dicts.

Divergences vs the legacy TypeScript behavior (kept intentionally small):
- Session ids are `sess_<epoch_ms>_<counter>` -- timestamp+counter based and
  deterministic for a fixed call sequence (legacy used bare Date.now()).
- Transcripts are JSONL (one message per line); legacy stored one big JSON
  record per session. JSONL tolerates partial/corrupt lines by skipping them.
- No auto-save timer, model-ref persistence, compaction backups, legacy
  latest.json migration, or retention pruning -- those belong to the runtime
  loop, not this pure persistence layer.
- `load_session` signals not-found by returning [] rather than null.
"""

import os;
import json;
import time;
import re;

glob _id_counter: int = 0,
     _last_ms: int = 0,
     _SESSION_ID_PATTERN: str = r"^sess_[0-9]+_[0-9]+$";


def _sessions_dir(cwd: str) -> str {
    return os.path.join(cwd, ".jackal", "sessions");
}


def _session_path(cwd: str, session_id: str) -> str {
    return os.path.join(_sessions_dir(cwd), session_id + ".jsonl");
}


def _index_path(cwd: str) -> str {
    return os.path.join(_sessions_dir(cwd), "index.json");
}


def is_valid_session_id(session_id: str) -> bool {
    return isinstance(session_id, str) and re.match(_SESSION_ID_PATTERN, session_id) is not None;
}


"""Fresh unique-but-deterministic id: epoch-milliseconds + process counter."""
def new_session_id() -> str {
    _id_counter += 1;
    return f"sess_{int(time.time() * 1000)}_{_id_counter}";
}


def _read_index(cwd: str) -> list {
    path = _index_path(cwd);
    if not os.path.exists(path) {
        return [];
    }
    fh = None;
    try {
        fh = open(path, "r");
        raw = json.load(fh);
    } except (OSError, ValueError) {
        return [];
    } finally {
        if fh is not None {
            fh.close();
        }
    }
    if not isinstance(raw, list) {
        return [];
    }
    entries: list = [];
    for item in raw {
        if isinstance(item, dict) and "id" in item {
            entries.append(item);
        }
    }
    return entries;
}


def _write_index(cwd: str, entries: list) {
    sdir = _sessions_dir(cwd);
    os.makedirs(sdir, exist_ok=True);
    fh = open(_index_path(cwd), "w");
    try {
        json.dump(entries, fh, indent=2);
        fh.write("\n");
    } finally {
        fh.close();
    }
}


def _entry_sort_key(rec: dict) -> str {
    return str(rec.get("updated", ""));
}


"""Monotonic (ISO, epoch-ms) timestamp pair: strictly increasing per process,
so same-millisecond saves still order deterministically newest-first."""
def _next_stamp() -> tuple[str, int] {
    ms = int(time.time() * 1000);
    if ms <= _last_ms {
        ms = _last_ms + 1;
    }
    _last_ms = ms;
    (secs, msec) = divmod(ms, 1000);
    iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(secs)) + f".{msec:03d}Z";
    return (iso, ms);
}


"""Order index-style records newest-updated first (stable on ties)."""
def _newest_first(records: list) -> list {
    return sorted(records, key=_entry_sort_key, reverse=True);
}


def _upsert_record(cwd: str, rec: dict) {
    entries = _read_index(cwd);
    replaced = False;
    for i in range(len(entries)) {
        if entries[i].get("id") == rec["id"] {
            entries[i] = rec;
            replaced = True;
            break;
        }
    }
    if not replaced {
        entries.append(rec);
    }
    _write_index(cwd, entries);
}


"""Persist a conversation as JSONL and refresh its index record.

Each element of `history` is written as one JSON object per line. Returns
metadata: {id, title, path, created, updated, turns}. Re-saving an existing
`session_id` preserves its original `created` stamp (and title when no new
title is given).
"""
def save_session(cwd: str, history: list, title: str = "", session_id: str = "") -> dict {
    sid = session_id if session_id else new_session_id();
    if not is_valid_session_id(sid) {
        raise ValueError("invalid session id: " + str(sid));
    }
    sdir = _sessions_dir(cwd);
    os.makedirs(sdir, exist_ok=True);
    path = _session_path(cwd, sid);
    (now, _stamp_ms) = _next_stamp();

    created = now;
    for entry in _read_index(cwd) {
        if entry.get("id") == sid {
            created = str(entry.get("created", now));
            if not title {
                title = str(entry.get("title", ""));
            }
            break;
        }
    }

    fh = open(path, "w");
    try {
        for msg in history {
            fh.write(json.dumps(msg) + "\n");
        }
    } finally {
        fh.close();
    }

    rec = {
        "id": sid,
        "title": title,
        "path": path,
        "created": created,
        "updated": now,
        "turns": len(history),
    };
    _upsert_record(cwd, rec);
    return rec;
}


"""Rebuild the message history for a saved session; [] when unknown.

Corrupt/partial JSONL lines are skipped rather than failing the load.
"""
def load_session(cwd: str, session_id: str) -> list {
    if not is_valid_session_id(session_id) {
        return [];
    }
    path = _session_path(cwd, session_id);
    if not os.path.exists(path) {
        return [];
    }
    history: list = [];
    fh = open(path, "r");
    try {
        for line in fh {
            stripped = line.strip();
            if not stripped {
                continue;
            }
            try {
                msg = json.loads(stripped);
            } except ValueError {
                continue;
            }
            if isinstance(msg, dict) and "role" in msg {
                history.append(msg);
            }
        }
    } finally {
        fh.close();
    }
    return history;
}


"""All sessions for a project, newest-updated first."""
def list_sessions(cwd: str) -> list {
    sdir = _sessions_dir(cwd);
    if not os.path.isdir(sdir) {
        return [];
    }
    entries = _read_index(cwd);
    # Directory-scan fallback: recover ids for files missing from the index.
    known: set[str] = set();
    for e in entries {
        known.add(str(e.get("id")));
    }
    for name in os.listdir(sdir) {
        if not name.endswith(".jsonl") {
            continue;
        }
        sid = name[:-len(".jsonl")];
        if sid in known or not is_valid_session_id(sid) {
            continue;
        }
        entries.append({
            "id": sid,
            "title": "",
            "path": _session_path(cwd, sid),
            "created": "",
            "updated": "",
            "turns": -1,
        });
    }
    return _newest_first(entries);
}


"""Set a session's title; True on success, False when the id is unknown."""
def rename_session(cwd: str, session_id: str, title: str) -> bool {
    trimmed = title.strip();
    if not trimmed or not is_valid_session_id(session_id) {
        return False;
    }
    if not os.path.exists(_session_path(cwd, session_id)) {
        return False;
    }
    entries = _read_index(cwd);
    found = False;
    for entry in entries {
        if entry.get("id") == session_id {
            entry["title"] = trimmed;
            found = True;
            break;
        }
    }
    if not found {
        return False;
    }
    _write_index(cwd, entries);
    return True;
}


"""Remove a session's transcript and index record; True if anything existed."""
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
    before = _read_index(cwd);
    after = [e for e in before if e.get("id") != session_id];
    if len(after) != len(before) or existed {
        _write_index(cwd, after);
    }
    return existed;
}


"""Id of the most recently updated session, or None when there are none."""
def latest_session_id(cwd: str) -> str | None {
    entries = list_sessions(cwd);
    if not entries {
        return None;
    }
    return str(entries[0].get("id"));
}
