"""Task store tests for agent/tasks.jac (ported from the Python toolchain
lib/jac/workflow/_tasks_toolchain.py).

Covers: exact persistence layout (<cwd>/.jackal/tasks.json, one JSON
array, indent=2 + trailing newline, camelCase keys), add/list round trips,
title/description stripping and null-coalescing, id shape (8 hex chars),
remove by index and by id including out-of-range/unknown lookups,
update_tasks status transitions (completedAt set/cleared) plus unknown-id
skips, clear writing an empty array, corrupt/non-list/partial-entry loads
returning [] or filtered results, task_counts, and both formatters.
Uses Python tempfile dirs (cleaned up per test) so no repo state is
touched -- never the real .jackal data.
"""

import os;
import json;
import re;
import time;
import tempfile;
import shutil;


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-tasks-test-");
}


def _cleanup(tmp: str) {
    shutil.rmtree(tmp, ignore_errors=True);
}


def _tasks_path(tmp: str) -> str {
    return os.path.join(tmp, ".jackal", "tasks.json");
}


def _read_raw(path: str) -> any {
    fh = open(path, "r");
    try {
        return json.load(fh);
    } finally {
        fh.close();
    }
}


def _write_text(path: str, text: str) {
    # Parent dir must already exist (callers create it).
    fh = open(path, "w");
    try {
        fh.write(text);
    } finally {
        fh.close();
    }
}


def _is_iso_utc(value: str) -> bool {
    # datetime.now(timezone.utc).isoformat() shape: 2026-05-23T13:38:24.261023+00:00
    return re.match(
        r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?\+00:00$", value
    ) is not None;
}


test "save writes tasks.json as an indent=2 array with camelCase keys" {
    tmp = _make_tmp();
    try {
        task = add_task(tmp, "ship the port");
        path = _tasks_path(tmp);
        assert os.path.exists(path);
        assert tasks_path(tmp) == path;

        raw_text = "";
        fh = open(path, "r");
        try {
            raw_text = fh.read();
        } finally {
            fh.close();
        }
        body = str(raw_text);
        assert body.endswith("\n") and not body.endswith("\n\n");
        assert '\n  [\n' in body or body.startswith("[\n");  # pretty-printed

        raw = _read_raw(path);
        assert isinstance(raw, list) and len(raw) == 1;
        entry: dict = raw[0];
        assert set(entry.keys()) == {"id", "title", "description", "status", "createdAt", "updatedAt"};
        assert entry["id"] == task["id"];
        assert entry["title"] == "ship the port";
        assert entry["description"] is None;  # blank description coalesces to null
        assert entry["status"] == "pending";
        assert _is_iso_utc(str(entry["createdAt"]));
        assert _is_iso_utc(str(entry["updatedAt"]));
        assert entry["createdAt"] == entry["updatedAt"];
        assert load_tasks(tmp) == [task];
    } finally {
        _cleanup(tmp);
    }
}


test "load returns [] for missing dir, missing file, corrupt json, non-list" {
    tmp = _make_tmp();
    try {
        assert load_tasks(tmp) == [];  # no .jackal dir at all

        tdir = os.path.join(tmp, ".jackal");
        os.makedirs(tdir, exist_ok=True);
        assert load_tasks(tmp) == [];  # dir exists but file does not

        _write_text(_tasks_path(tmp), "{not valid json at all");
        assert load_tasks(tmp) == [];

        _write_text(_tasks_path(tmp), '{"not": "a list"}');
        assert load_tasks(tmp) == [];
    } finally {
        _cleanup(tmp);
    }
}


test "load filters entries that miss required fields or have wrong types" {
    tmp = _make_tmp();
    try {
        good = add_task(tmp, "real task");
        raw: any = _read_raw(_tasks_path(tmp));
        raw.insert(0, {"id": "abc12345"});  # missing fields
        raw.append({"id": 7, "title": "num id", "status": "pending",
                    "createdAt": "x", "updatedAt": "y"});  # wrong id type
        raw.append("just a string");  # not a dict
        fh = open(_tasks_path(tmp), "w");
        try {
            json.dump(raw, fh, indent=2);
            fh.write("\n");
        } finally {
            fh.close();
        }

        loaded = load_tasks(tmp);
        assert loaded == [good];
    } finally {
        _cleanup(tmp);
    }
}


test "add_task strips inputs, keeps description when given, appends in order" {
    tmp = _make_tmp();
    try {
        first = add_task(tmp, "  write module  ", "  with care ");
        second = add_task(tmp, "second", "");
        third = add_task(tmp, "third");

        assert first["title"] == "write module";
        assert first["description"] == "with care";
        assert second["description"] is None;

        tasks = load_tasks(tmp);
        assert [str(t["id"]) for t in tasks] == [first["id"], second["id"], third["id"]];
        assert [str(t["title"]) for t in tasks] == ["write module", "second", "third"];

        # Ids are uuid4 prefixes: exactly 8 lowercase hex chars.
        ids: set[str] = set();
        for t in tasks {
            assert re.match(r"^[0-9a-f]{8}$", str(t["id"])) is not None;
            ids.add(str(t["id"]));
        }
        assert len(ids) == 3;
        assert len(generate_task_id()) == 8;
    } finally {
        _cleanup(tmp);
    }
}


test "remove by index honors bounds and shifts remaining tasks" {
    tmp = _make_tmp();
    try {
        a = add_task(tmp, "one");
        b = add_task(tmp, "two");
        c = add_task(tmp, "three");

        removed = remove_task_by_index(tmp, 1);
        assert removed is not None;
        assert removed["id"] == b["id"];
        assert [str(t["id"]) for t in load_tasks(tmp)] == [a["id"], c["id"]];

        # Out of range and negative indices return None without touching disk.
        assert remove_task_by_index(tmp, 5) is None;
        assert remove_task_by_index(tmp, -1) is None;
        assert len(load_tasks(tmp)) == 2;

        assert remove_task_by_index(tmp, 1) is not None;  # now the last one
        assert len(load_tasks(tmp)) == 1;
    } finally {
        _cleanup(tmp);
    }
}


test "remove by id matches first occurrence and None when unknown" {
    tmp = _make_tmp();
    try {
        a = add_task(tmp, "alpha");
        b = add_task(tmp, "beta");
        assert remove_task_by_id(tmp, "zzzzzzzz") is None;
        got = remove_task_by_id(tmp, str(a["id"]));
        assert got is not None and got["id"] == a["id"];
        assert [str(t["id"]) for t in load_tasks(tmp)] == [b["id"]];
        assert remove_task_by_id(tmp, str(a["id"])) is None;  # already gone
    } finally {
        _cleanup(tmp);
    }
}


test "update_tasks sets completedAt on completed and clears it otherwise" {
    tmp = _make_tmp();
    try {
        a = add_task(tmp, "first");
        b = add_task(tmp, "second");

        updated = update_tasks(tmp, [{"id": a["id"], "status": "in_progress"}]);
        ta: dict = {};
        for t in updated {
            if str(t["id"]) == a["id"] {
                ta = t;
            }
        }
        assert ta["status"] == "in_progress";
        assert ta["completedAt"] is None;
        assert _is_iso_utc(str(ta["updatedAt"]));
        # Unmatched task untouched (same object values as saved).
        assert load_tasks(tmp)[1]["id"] == b["id"];
        assert load_tasks(tmp)[1]["status"] == "pending";

        done = update_tasks(tmp, [{"id": a["id"], "status": "completed"}]);
        for t in done {
            if str(t["id"]) == a["id"] {
                assert t["completedAt"] is not None;
                assert _is_iso_utc(str(t["completedAt"]));
                assert t["updatedAt"] == t["completedAt"];
            }
        }

        # Any non-completed status clears completedAt again.
        reopened = update_tasks(tmp, [{"id": a["id"], "status": "pending"}]);
        for t in reopened {
            if str(t["id"]) == a["id"] {
                assert t["completedAt"] is None;
            }
        }
    } finally {
        _cleanup(tmp);
    }
}


test "update_tasks edits title/description, bumps updatedAt, skips unknown ids" {
    tmp = _make_tmp();
    try {
        a = add_task(tmp, "before", "old blurb");
        before_updated: str = str(a["updatedAt"]);
        time.sleep(0.01);

        result = update_tasks(tmp, [
            {"id": a["id"], "title": "after", "description": "new blurb"},
            {"id": "no-such-id", "status": "completed"},
        ]);
        assert len(result) == 1;
        assert result[0]["title"] == "after";
        assert result[0]["description"] == "new blurb";
        assert result[0]["updatedAt"] != before_updated;
        # Unknown id did not create anything or crash.
        assert len(load_tasks(tmp)) == 1;

        # Description can be explicitly nulled via update.
        nulled = update_tasks(tmp, [{"id": a["id"], "description": None}]);
        assert nulled[0]["description"] is None;
    } finally {
        _cleanup(tmp);
    }
}


test "clear_tasks writes an empty array instead of deleting the file" {
    tmp = _make_tmp();
    try {
        add_task(tmp, "doomed");
        assert clear_tasks(tmp);
        assert load_tasks(tmp) == [];
        assert os.path.exists(_tasks_path(tmp));
        assert _read_raw(_tasks_path(tmp)) == [];
    } finally {
        _cleanup(tmp);
    }
}


test "task_counts buckets by status and ignores foreign statuses" {
    tmp = _make_tmp();
    try {
        p = add_task(tmp, "p");
        i = add_task(tmp, "i");
        c = add_task(tmp, "c");
        update_tasks(tmp, [{"id": i["id"], "status": "in_progress"}]);
        update_tasks(tmp, [{"id": c["id"], "status": "completed"}]);

        counts = task_counts(load_tasks(tmp));
        assert counts == {"pending": 1, "in_progress": 1, "completed": 1};

        raw: any = _read_raw(_tasks_path(tmp));
        raw.append({"id": "ffffffff", "title": "weird", "status": "cancelled",
                    "createdAt": "t", "updatedAt": "t"});
        assert task_counts(raw)["pending"] == 1;
        assert task_counts([]) == {"pending": 0, "in_progress": 0, "completed": 0};
    } finally {
        _cleanup(tmp);
    }
}


test "format_task_line picks icons per status and renders optional blurb" {
    tmp = _make_tmp();
    try {
        plain: dict = {"id": "aaaa1111", "title": "plain", "description": None,
                       "status": "pending", "createdAt": "t", "updatedAt": "t"};
        running: dict = dict(plain);
        running["status"] = "in_progress";
        done: dict = dict(plain);
        done["status"] = "completed";
        with_desc: dict = dict(plain);
        with_desc["description"] = "the details";

        line = format_task_line(with_desc);
        assert line == "○ [aaaa1111] plain — the details";
        assert format_task_line(running).startswith("◐ [aaaa1111]");
        assert format_task_line(done).startswith("✓ [aaaa1111]");
        assert format_task_line(plain) == "○ [aaaa1111] plain";

        # Legacy files may omit description entirely; must not crash.
        bare: dict = {"id": "bbbb2222", "title": "bare", "status": "pending"};
        assert format_task_line(bare) == "○ [bbbb2222] bare";
    } finally {
        _cleanup(tmp);
    }
}


test "format_tasks_list renders header with counts or the empty hint" {
    tmp = _make_tmp();
    try {
        assert format_tasks_list([]) == "No tasks. Use /tasks add <title> or create_task.";

        a = add_task(tmp, "alpha");
        b = add_task(tmp, "beta");
        c = add_task(tmp, "gamma");
        update_tasks(tmp, [{"id": b["id"], "status": "in_progress"}]);
        update_tasks(tmp, [{"id": c["id"], "status": "completed"}]);

        board = format_tasks_list(load_tasks(tmp), title="Board");
        lines = board.split("\n");
        assert lines[0] == "Board (1 pending, 1 in progress, 1 completed)";
        assert lines[1] == "─" * 50;
        assert lines[2].startswith(f"1. ○ [{a['id']}] alpha");
        assert lines[3].startswith(f"2. ◐ [{b['id']}] beta");
        assert lines[4].startswith(f"3. ✓ [{c['id']}] gamma");
        # Default title when omitted.
        assert format_tasks_list(load_tasks(tmp)).startswith("Tasks (");
    } finally {
        _cleanup(tmp);
    }
}


test "store survives reopen: every op reads fresh state from disk" {
    tmp = _make_tmp();
    try {
        # Mutations never carry stale in-memory lists across calls.
        add_task(tmp, "one");
        add_task(tmp, "two");
        # Simulate another process appending directly to the file.
        raw: any = _read_raw(_tasks_path(tmp));
        raw.append({"id": "deadbeef", "title": "external", "description": None,
                    "status": "pending", "createdAt": "t", "updatedAt": "t"});
        fh = open(_tasks_path(tmp), "w");
        try {
            json.dump(raw, fh, indent=2);
            fh.write("\n");
        } finally {
            fh.close();
        }
        # Next mutation sees the external edit too.
        gone = remove_task_by_id(tmp, "deadbeef");
        assert gone is not None and gone["title"] == "external";
        left = load_tasks(tmp);
        assert len(left) == 2;
        assert [str(t["title"]) for t in left] == ["one", "two"];
    } finally {
        _cleanup(tmp);
    }
}
