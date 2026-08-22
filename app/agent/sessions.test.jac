"""Session persistence tests for the legacy-compatible agent/sessions.jac.

Covers: save/load round trips in the legacy six-key transcript format,
interop with a fixture byte-identical to the verified legacy sample,
index+scan merge with newest-first ordering and messageCount, rename
touching both transcript and index, delete of both artifacts, corrupt or
unreadable transcripts being skipped, missing/corrupt index fallback and
rebuild, id format, same-millisecond id uniqueness, and latest-session
resolution. Uses Python tempfile dirs (cleaned up per test) so no repo
state is touched -- never the real .jackal/sessions data.
"""

import os;
import json;
import re;
import tempfile;
import shutil;


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-sessions-test-");
}


def _cleanup(tmp: str) {
    shutil.rmtree(tmp, ignore_errors=True);
}


def _hist(*exchanges: str) -> list {
    out: list = [{"role": "system", "content": "sys prompt"}];
    for text in exchanges {
        out.append({"role": "user", "content": text});
        out.append({"role": "assistant", "content": "reply: " + text});
    }
    return out;
}


def _sessions_dir(tmp: str) -> str {
    return os.path.join(tmp, ".jackal", "sessions");
}


def _read_raw(path: str) {
    fh = open(path, "r");
    try {
        return json.load(fh);
    } finally {
        fh.close();
    }
}


def _write_text(path: str, text: str) {
    os.makedirs(os.path.dirname(path), exist_ok=True);
    fh = open(path, "w");
    try {
        fh.write(text);
    } finally {
        fh.close();
    }
}


def _is_iso_z(value: str) -> bool {
    return re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", value) is not None;
}


test "save then load round-trips the legacy six-key record" {
    tmp = _make_tmp();
    try {
        hist = _hist("hello", "how are you");
        meta = save_session(tmp, hist);
        assert isinstance(meta, dict);
        assert meta["name"] == "new session";
        assert meta["messageCount"] == len(hist);
        assert os.path.exists(meta["path"]);
        assert meta["path"].endswith(".json");

        raw = _read_raw(meta["path"]);
        assert set(raw.keys()) == {"sessionId", "sessionName", "cwd", "createdAt", "updatedAt", "messages"};
        assert raw["sessionId"] == meta["id"];
        assert raw["sessionName"] == "new session";
        assert raw["cwd"] == tmp;
        assert _is_iso_z(raw["createdAt"]);
        assert _is_iso_z(raw["updatedAt"]);
        assert isinstance(raw["messages"], list);
        assert raw["messages"] == hist;

        loaded = load_session(tmp, str(meta["id"]));
        assert loaded == hist;

        # Re-saving under the same id preserves identity, created stamp,
        # and prior name when no new name is given.
        again = save_session(tmp, _hist("more"), session_id=str(meta["id"]));
        assert again["id"] == meta["id"];
        assert again["created"] == meta["created"];
        assert again["name"] == "new session";
        assert load_session(tmp, str(meta["id"])) == _hist("more");
        assert list_sessions(tmp)[0]["messageCount"] == 3;
    } finally {
        _cleanup(tmp);
    }
}


test "legacy fixture file loads and lists exactly like the real runtime wrote it" {
    tmp = _make_tmp();
    try {
        fixture = '{"sessionId": "sess_1779521512249", "sessionName": "new session", "cwd": "/home/jac/repos/jackal", "createdAt": "2026-05-23T13:38:24.261Z", "updatedAt": "2026-05-23T13:45:44.126Z", "messages": [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}]}';
        index_fixture = '[{"id": "sess_1779521512249", "name": "new session", "cwd": "/home/jac/repos/jackal", "updatedAt": "2026-05-23T13:45:44.126Z", "messageCount": 2}]';
        sdir = _sessions_dir(tmp);
        os.makedirs(sdir, exist_ok=True);
        _write_text(os.path.join(sdir, "sess_1779521512249.json"), fixture);
        _write_text(os.path.join(sdir, "index.json"), index_fixture);

        loaded = load_session(tmp, "sess_1779521512249");
        assert loaded == [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}];

        entries = list_sessions(tmp);
        assert len(entries) == 1;
        item = entries[0];
        assert item["id"] == "sess_1779521512249";
        assert item["name"] == "new session";
        assert item["cwd"] == "/home/jac/repos/jackal";
        assert item["updatedAt"] == "2026-05-23T13:45:44.126Z";
        assert item["messageCount"] == 2;
        assert latest_session_id(tmp) == "sess_1779521512249";

        # Our own save must emit all six keys too, so the legacy runtime
        # can read our files back.
        hist = [{"role": "user", "content": "ours"}];
        meta = save_session(tmp, hist, name="renamed by us");
        ours = _read_raw(meta["path"]);
        assert set(ours.keys()) == {"sessionId", "sessionName", "cwd", "createdAt", "updatedAt", "messages"};
        assert ours["messages"] == hist;
        assert load_session(tmp, str(meta["id"])) == hist;
    } finally {
        _cleanup(tmp);
    }
}


test "list_sessions merges index and directory scan newest first with counts" {
    tmp = _make_tmp();
    try {
        m1 = save_session(tmp, _hist("first"), name="oldest chat");
        m2 = save_session(tmp, _hist("second"), name="newest chat");
        # Orphan transcript absent from the index, stamped oldest.
        orphan = '{"sessionId": "sess_111111111111", "sessionName": "orphan scan", "cwd": "' + tmp + '", "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z", "messages": [{"role": "user", "content": "a"}, {"role": "assistant", "content": "b"}, {"role": "user", "content": "c"}]}';
        _write_text(os.path.join(_sessions_dir(tmp), "sess_111111111111.json"), orphan);

        entries = list_sessions(tmp);
        assert [str(e["id"]) for e in entries] == [m2["id"], m1["id"], "sess_111111111111"];
        assert entries[0]["name"] == "newest chat";
        assert entries[1]["name"] == "oldest chat";
        assert entries[2]["name"] == "orphan scan";
        assert entries[0]["messageCount"] == 3;
        assert entries[2]["messageCount"] == 3;
        for item in entries {
            assert isinstance(item["messageCount"], int);
            assert _is_iso_z(str(item["updatedAt"]));
        }

        empty = _make_tmp();
        try {
            assert list_sessions(empty) == [];
            assert latest_session_id(empty) is None;
        } finally {
            _cleanup(empty);
        }
    } finally {
        _cleanup(tmp);
    }
}


test "rename updates BOTH transcript sessionName and index name" {
    tmp = _make_tmp();
    try {
        hist = _hist("a");
        meta = save_session(tmp, hist, name="before");
        assert rename_session(tmp, str(meta["id"]), "after");

        raw = _read_raw(meta["path"]);
        assert raw["sessionName"] == "after";
        assert raw["messages"] == hist;
        assert raw["createdAt"] == meta["created"];

        index_raw = _read_raw(os.path.join(_sessions_dir(tmp), "index.json"));
        names = {str(e["id"]): str(e["name"]) for e in index_raw};
        assert names[meta["id"]] == "after";

        entries = list_sessions(tmp);
        assert str(entries[0]["name"]) == "after";
        assert str(entries[0]["id"]) == meta["id"];
        assert load_session(tmp, str(meta["id"])) == hist;

        # Unknown ids, blank names, and traversal attempts fail cleanly.
        assert not rename_session(tmp, "sess_999999999999", "nope");
        assert not rename_session(tmp, str(meta["id"]), "   ");
        assert not rename_session(tmp, "../escape", "nope");
    } finally {
        _cleanup(tmp);
    }
}


test "delete removes transcript and index entry" {
    tmp = _make_tmp();
    try {
        keep = save_session(tmp, _hist("keep"), name="kept");
        gone = save_session(tmp, _hist("gone"), name="deleted");
        assert delete_session(tmp, str(gone["id"]));
        assert not os.path.exists(str(gone["path"]));

        index_raw = _read_raw(os.path.join(_sessions_dir(tmp), "index.json"));
        ids = [str(e["id"]) for e in index_raw];
        assert gone["id"] not in ids;
        assert keep["id"] in ids;

        listed = [str(e["id"]) for e in list_sessions(tmp)];
        assert gone["id"] not in listed;
        assert keep["id"] in listed;
        assert load_session(tmp, str(gone["id"])) == [];

        # Second delete is a no-op returning False; unknown/invalid ids too.
        assert not delete_session(tmp, str(gone["id"]));
        assert not delete_session(tmp, "sess_424242424242");
        assert not delete_session(tmp, "../escape");
    } finally {
        _cleanup(tmp);
    }
}


test "corrupt and non-record transcript files are skipped without crashing" {
    tmp = _make_tmp();
    try {
        good = save_session(tmp, _hist("good"), name="good one");
        _write_text(os.path.join(_sessions_dir(tmp), "sess_123456789012.json"), "{this is not json at all");
        _write_text(os.path.join(_sessions_dir(tmp), "sess_123456789013.json"), "[1, 2, 3]");
        _write_text(os.path.join(_sessions_dir(tmp), "sess_123456789014.json"), '{"sessionId": "other-id", "sessionName": "mismatch", "cwd": "x", "updatedAt": "2026-01-01T00:00:00.000Z", "messages": []}');
        _write_text(os.path.join(_sessions_dir(tmp), "not-a-session.txt"), "ignored");

        entries = list_sessions(tmp);
        assert [str(e["id"]) for e in entries] == [good["id"]];
        assert load_session(tmp, "sess_123456789012") == [];
        assert load_session(tmp, "sess_123456789013") == [];
        assert load_session(tmp, "sess_123456789014") == [];
        assert load_session(tmp, str(good["id"])) == _hist("good");
    } finally {
        _cleanup(tmp);
    }
}


test "missing or corrupt index falls back to scan and gets rebuilt" {
    tmp = _make_tmp();
    try {
        m1 = save_session(tmp, _hist("one"), name="first");
        m2 = save_session(tmp, _hist("two"), name="second");
        index_path = os.path.join(_sessions_dir(tmp), "index.json");

        os.remove(index_path);
        entries = list_sessions(tmp);
        assert [str(e["id"]) for e in entries] == [m2["id"], m1["id"]];
        assert entries[0]["name"] == "second";
        rebuilt = _read_raw(index_path);
        assert sorted(str(e["id"]) for e in rebuilt) == sorted([m1["id"], m2["id"]]);

        _write_text(index_path, "}{ total garbage {");
        entries = list_sessions(tmp);
        assert [str(e["id"]) for e in entries] == [m2["id"], m1["id"]];
        assert latest_session_id(tmp) == m2["id"];

        assert delete_session(tmp, str(m2["id"]));
        assert delete_session(tmp, str(m1["id"]));
        assert latest_session_id(tmp) is None;
    } finally {
        _cleanup(tmp);
    }
}


test "ids are sess_<epoch_ms> digits-only and never collide within a millisecond" {
    tmp = _make_tmp();
    try {
        first = new_session_id();
        second = new_session_id();
        assert re.match(r"^sess_[0-9]+$", first) is not None;
        assert re.match(r"^sess_[0-9]+$", second) is not None;
        assert first != second;
        assert int(first[5:]) <= int(second[5:]);

        m1 = save_session(tmp, _hist("x"), name="a");
        m2 = save_session(tmp, _hist("y"), name="b");
        assert re.match(r"^sess_[0-9]+$", str(m1["id"])) is not None;
        assert re.match(r"^sess_[0-9]+$", str(m2["id"])) is not None;
        assert m1["id"] != m2["id"];

        # Explicitly passing an invalid id raises rather than corrupting disk.
        failed = False;
        try {
            save_session(tmp, [], name="bad", session_id="../escape");
        } except ValueError {
            failed = True;
        }
        assert failed;
        assert load_session(tmp, "../../etc/passwd") == [];
        assert load_session(tmp, "") == [];
    } finally {
        _cleanup(tmp);
    }
}


test "latest_session_id resolves the most recently saved session" {
    tmp = _make_tmp();
    try {
        m1 = save_session(tmp, _hist("one"), name="one");
        m2 = save_session(tmp, _hist("two"), name="two");
        m3 = save_session(tmp, _hist("three"), name="three");
        assert latest_session_id(tmp) == m3["id"];
        # Renaming bumps updatedAt, making the renamed session latest.
        assert rename_session(tmp, str(m1["id"]), "touched");
        assert latest_session_id(tmp) == m1["id"];
        assert delete_session(tmp, str(m1["id"]));
        assert delete_session(tmp, str(m2["id"]));
        assert delete_session(tmp, str(m3["id"]));
        assert latest_session_id(tmp) is None;
    } finally {
        _cleanup(tmp);
    }
}


test "model ref persists as optional seventh key and stays byte-compatible without one" {
    tmp = _make_tmp();
    try {
        # No model -> exactly the legacy six keys.
        meta = save_session(tmp, _hist("a"), name="plain");
        raw = _read_raw(meta["path"]);
        assert set(raw.keys()) == {
            "sessionId", "sessionName", "cwd", "createdAt", "updatedAt",
            "messages",
        };
        assert meta["model"] == "";

        # With model -> seventh key present; re-save without arg keeps it.
        m2 = save_session(tmp, _hist("b"), name="with-model",
                          session_id=str(meta["id"]), model="openrouter/anthropic/claude-sonnet-5");
        assert m2["model"] == "openrouter/anthropic/claude-sonnet-5";
        rec = get_session_record(tmp, str(m2["id"]));
        assert rec is not None;
        assert rec["model"] == "openrouter/anthropic/claude-sonnet-5";

        # Re-save with no model argument preserves the prior model ref.
        m3 = save_session(tmp, _hist("c"), session_id=str(m2["id"]));
        assert m3["model"] == "openrouter/anthropic/claude-sonnet-5";
    } finally {
        _cleanup(tmp);
    }
}


test "get_session_record returns None for unknown or invalid ids" {
    tmp = _make_tmp();
    try {
        assert get_session_record(tmp, "sess_123456789") is None;
        assert get_session_record(tmp, "../escape") is None;
        meta = save_session(tmp, _hist("x"));
        rec = get_session_record(tmp, str(meta["id"]));
        assert rec is not None;
        assert rec["sessionId"] == meta["id"];
    } finally {
        _cleanup(tmp);
    }
}


test "export_session writes readable markdown from a transcript" {
    tmp = _make_tmp();
    out_path = os.path.join(tmp, "export", "out.md");
    try {
        hist = [
            {"role": "system", "content": "hidden system prompt"},
            {"role": "user", "content": "list the files"},
            {"role": "assistant", "content": "", "tool_calls": [
                {"id": "c1", "type": "function",
                 "function": {"name": "list_dir", "arguments": "{\"path\": \".\"}"}},
            ]},
            {"role": "tool", "tool_call_id": "c1", "content": "src/\napp.jac"},
            {"role": "assistant", "content": "here they are"},
        ];
        meta = save_session(tmp, hist, name="probe run",
                            model="openrouter/anthropic/claude-sonnet-5");
        assert export_session(tmp, str(meta["id"]), out_path);
        text: any = "";
        fh = open(out_path, "r");
        try {
            text = fh.read();
        } finally {
            fh.close();
        }
        body = str(text);
        assert "# probe run" in body;
        assert "- model: openrouter/anthropic/claude-sonnet-5" in body;
        assert "## user" in body and "list the files" in body;
        assert "**tool call: list_dir**" in body;
        assert "```json" in body and "{\"path\": \".\"}" in body;
        assert "### tool result" in body and "src/" in body;
        assert "here they are" in body;
        # System prompt must not leak into the export.
        assert "hidden system prompt" not in body;

        # Unknown id and unwritable target both fail cleanly.
        assert not export_session(tmp, "sess_987654321", out_path);
        assert not export_session(tmp, str(meta["id"]), "/proc/nope/out.md");
    } finally {
        _cleanup(tmp);
    }
}
