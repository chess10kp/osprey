"""Session persistence tests (agent/sessions.jac).

Covers: save/load round trips, newest-first listing with titles, rename,
delete, missing-id behavior, corrupt-JSONL tolerance, and latest-session
resolution. Uses Python tempfile dirs (cleaned up per test) so no repo
state is touched.
"""

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


test "save then load round-trips messages exactly" {
    tmp = _make_tmp();
    try {
        hist = _hist("hello", "how are you");
        meta = save_session(tmp, hist, title="chat one");
        assert isinstance(meta, dict);
        assert meta["title"] == "chat one";
        assert meta["turns"] == len(hist);
        assert os.path.exists(meta["path"]);
        assert meta["path"].endswith(".jsonl");
        loaded = load_session(tmp, str(meta["id"]));
        assert loaded == hist;
        # Re-saving under the same id preserves identity + created stamp.
        again = save_session(tmp, _hist("more"), title="", session_id=str(meta["id"]));
        assert again["id"] == meta["id"];
        assert again["created"] == meta["created"];
        assert load_session(tmp, str(meta["id"])) == _hist("more");
    } finally {
        _cleanup(tmp);
    }
}


test "list_sessions orders newest first and carries titles" {
    tmp = _make_tmp();
    try {
        m1 = save_session(tmp, _hist("first"), title="oldest chat");
        m2 = save_session(tmp, _hist("second"), title="newest chat");
        entries = list_sessions(tmp);
        assert len(entries) == 2;
        assert str(entries[0]["id"]) == m2["id"];
        assert str(entries[1]["id"]) == m1["id"];
        assert str(entries[0]["title"]) == "newest chat";
        assert str(entries[1]["title"]) == "oldest chat";
        # Empty project has no sessions at all.
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


test "rename updates the persisted title only" {
    tmp = _make_tmp();
    try {
        meta = save_session(tmp, _hist("a"), title="before");
        assert rename_session(tmp, str(meta["id"]), "after");
        entries = list_sessions(tmp);
        assert str(entries[0]["title"]) == "after";
        assert str(entries[0]["id"]) == meta["id"];
        # Transcript untouched by rename.
        assert load_session(tmp, str(meta["id"])) == _hist("a");
        # Unknown id / blank title fail without side effects.
        assert not rename_session(tmp, "sess_999999999999_99", "nope");
        assert not rename_session(tmp, str(meta["id"]), "   ");
    } finally {
        _cleanup(tmp);
    }
}


test "delete removes transcript and index entry" {
    tmp = _make_tmp();
    try {
        keep = save_session(tmp, _hist("keep"), title="kept");
        gone = save_session(tmp, _hist("gone"), title="deleted");
        assert delete_session(tmp, str(gone["id"]));
        assert not os.path.exists(str(gone["path"]));
        ids = [str(e["id"]) for e in list_sessions(tmp)];
        assert gone["id"] not in ids;
        assert keep["id"] in ids;
        assert load_session(tmp, str(gone["id"])) == [];
        # Second delete is a no-op returning False; unknown/invalid ids too.
        assert not delete_session(tmp, str(gone["id"]));
        assert not delete_session(tmp, "sess_424242424242_42");
        assert not delete_session(tmp, "../escape");
    } finally {
        _cleanup(tmp);
    }
}


test "loading a missing or malformed session id yields empty history" {
    tmp = _make_tmp();
    try {
        save_session(tmp, _hist("x"), title="t");
        assert load_session(tmp, "sess_111111111111_11") == [];
        assert load_session(tmp, "bogus-id") == [];
        assert load_session(tmp, "") == [];
        assert load_session(tmp, "../../etc/passwd") == [];
    } finally {
        _cleanup(tmp);
    }
}


test "corrupt JSONL lines are skipped without failing the load" {
    tmp = _make_tmp();
    try {
        hist = _hist("good");
        meta = save_session(tmp, hist, title="partial");
        # Splice corrupt content between valid lines on disk.
        fh = open(str(meta["path"]), "w");
        try {
            fh.write(json.dumps(hist[0]) + "\n");
            fh.write("{this is not json\n");
            fh.write("\n");
            fh.write(json.dumps({"role": "assistant", "content": "ok"}) + "\n");
            fh.write("[1, 2, 3]\n");
        } finally {
            fh.close();
        }
        loaded = load_session(tmp, str(meta["id"]));
        assert loaded == [hist[0], {"role": "assistant", "content": "ok"}];
    } finally {
        _cleanup(tmp);
    }
}


test "latest_session_id resolves the most recently saved session" {
    tmp = _make_tmp();
    try {
        m1 = save_session(tmp, _hist("one"), title="one");
        m2 = save_session(tmp, _hist("two"), title="two");
        m3 = save_session(tmp, _hist("three"), title="three");
        assert latest_session_id(tmp) == m3["id"];
        assert delete_session(tmp, str(m3["id"]));
        assert latest_session_id(tmp) == m2["id"];
        assert delete_session(tmp, str(m2["id"]));
        assert delete_session(tmp, str(m1["id"]));
        assert latest_session_id(tmp) is None;
    } finally {
        _cleanup(tmp);
    }
}
