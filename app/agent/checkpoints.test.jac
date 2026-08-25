"""Checkpoint store tests for agent/checkpoints.jac (ported from
lib/jac/workflow/_checkpoints_toolchain.py).

Covers: create with the documented .jackal/checkpoints/<name>/ layout,
auto-generated timestamped names and duplicate rejection, every name
validation branch, description derivation and 80-char truncation, git
modification detection in throwaway repos, load round trips, corrupt or
missing store files surfacing as ValueError/OSError, list ordering with
sizeBytes and junk skipping, delete semantics, restore write-backs
including nested paths and aggregated failure, a full modify -> snapshot
-> modify -> restore git round trip, and the humanized formatting
helpers. Uses Python tempfile dirs (cleaned up per test) and throwaway
`git init` repos with local user config so no repo state is touched --
never the real .jackal/checkpoints data.
"""

import os;
import json;
import re;
import shutil;
import subprocess;
import tempfile;
import datetime;


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-checkpoints-test-");
}


def _cleanup(tmp: str) {
    shutil.rmtree(tmp, ignore_errors=True);
}


def _cp_dir(tmp: str) -> str {
    return os.path.join(tmp, ".jackal", "checkpoints");
}


def _write_file(base: str, rel: str, content: str) {
    path: str = os.path.join(base, rel);
    dn: any = os.path.dirname;
    os.makedirs(str(dn(path)), exist_ok=True);
    fh: any = open(path, "w");
    try {
        fh.write(content);
    } finally {
        fh.close();
    }
}


def _read_file(path: str) -> str {
    fh: any = open(path, "r");
    try {
        return fh.read();
    } finally {
        fh.close();
    }
}


def _read_raw(path: str) -> any {
    fh: any = open(path, "r");
    try {
        return json.load(fh);
    } finally {
        fh.close();
    }
}


def _git(args: list[str], repo: str) {
    subprocess.run(
        ["git"] + args, cwd=repo, capture_output=True, text=True, timeout=15,
    );
}


"""Throwaway repo under tmp/repo with local identity and one commit."""
def _init_git_repo(tmp: str) -> str {
    repo = os.path.join(tmp, "repo");
    os.makedirs(repo, exist_ok=True);
    _git(["init"], repo);
    _git(["config", "user.email", "test@example.com"], repo);
    _git(["config", "user.name", "Jackal Tests"], repo);
    _write_file(repo, "base.txt", "base v1\n");
    _git(["add", "."], repo);
    _git(["commit", "-m", "initial"], repo);
    return repo;
}


def _msgs(*texts: str) -> list {
    out: list = [];
    for t in texts {
        out.append({"role": "user", "content": t});
        out.append({"role": "assistant", "content": "ok"});
    }
    return out;
}


def _iso_ago(seconds: float = 0, minutes: float = 0, hours: float = 0, days: float = 0) -> str {
    delta = datetime.timedelta(seconds=seconds, minutes=minutes, hours=hours, days=days);
    return (datetime.datetime.now(datetime.timezone.utc) - delta).isoformat();
}


test "create writes the documented layout and exact metadata keys" {
    tmp = _make_tmp();
    try {
        _write_file(tmp, "src/a.txt", "alpha");
        _write_file(tmp, "lib/deep/b.txt", "beta");
        msgs = _msgs("hello there");
        meta = create_checkpoint(
            tmp, msgs, "prov", "model-x", name="first",
            modified_files=["src/a.txt", "lib/deep/b.txt"],
        );
        assert isinstance(meta, dict);
        assert set(meta.keys()) == {
            "name", "timestamp", "messageCount", "filesChanged",
            "provider", "description", "gitCommitHash",
        };
        assert meta["name"] == "first";
        assert meta["messageCount"] == len(msgs);
        assert meta["filesChanged"] == ["src/a.txt", "lib/deep/b.txt"];
        assert meta["provider"] == {"name": "prov", "model": "model-x"};
        # Non-git directory: no HEAD hash available.
        assert meta["gitCommitHash"] is None;

        cp = os.path.join(_cp_dir(tmp), "first");
        meta_path = os.path.join(cp, "metadata.json");
        conv_path = os.path.join(cp, "conversation.json");
        assert os.path.exists(meta_path) and os.path.exists(conv_path);
        raw_meta = _read_file(meta_path);
        assert raw_meta.endswith("\n");
        assert '"name": "first"' in raw_meta;  # indent=2 signature

        stored_meta = _read_raw(meta_path);
        assert stored_meta == meta;
        conv = _read_raw(conv_path);
        assert set(conv.keys()) == {"messages"};
        assert conv["messages"] == msgs;

        assert os.path.exists(os.path.join(cp, "files", "src", "a.txt"));
        assert _read_file(os.path.join(cp, "files", "lib", "deep", "b.txt")) == "beta";
    } finally {
        _cleanup(tmp);
    }
}


test "create auto-generates timestamped names and rejects duplicates" {
    tmp = _make_tmp();
    try {
        meta = create_checkpoint(tmp, [], "p", "m");
        assert re.match(r"^checkpoint-\d{4}-\d{2}-\d{2}-", str(meta["name"])) is not None;
        assert os.path.isdir(os.path.join(_cp_dir(tmp), str(meta["name"])));

        # Blank/whitespace names fall through to auto-generation too.
        meta2 = create_checkpoint(tmp, [], "p", "m", name="   ");
        assert str(meta2["name"]).startswith("checkpoint-");

        # An explicit name can only be used once.
        create_checkpoint(tmp, [], "p", "m", name="dupe");
        failed = False;
        try {
            create_checkpoint(tmp, [], "p", "m", name="dupe");
        } except ValueError {
            failed = True;
        }
        assert failed;
    } finally {
        _cleanup(tmp);
    }
}


test "validate_checkpoint_name covers every rejection branch" {
    cases: list = [
        ("", "empty"),
        ("   ", "empty"),
        ("x" * 101, "100 characters"),
        ("bad:name", "invalid characters"),
        ("bad/name", "invalid characters"),
        ("bad\\name", "invalid characters"),
        ("bad*name", "invalid characters"),
        ("bad?name", "invalid characters"),
        (".dotstart", "dot or space"),
        ("dotend.", "dot or space"),
        (" spacestart", "dot or space"),
        ("spaceend ", "dot or space"),
    ];
    for pair in cases {
        res = validate_checkpoint_name(str(pair[0]));
        assert res["valid"] is False;
        assert pair[1] in str(res.get("error"));
    }
    ok = validate_checkpoint_name("release 1.2-final_ok");
    assert ok["valid"] is True;
    assert ok.get("error") is None;
}


test "description uses the first user message and truncates at 80 chars" {
    long_text = "y" * 120;
    tmp = _make_tmp();
    try {
        meta = create_checkpoint(tmp, [{"role": "user", "content": long_text}], "p", "m");
        assert meta["description"] == "y" * 80 + "...";
    } finally {
        _cleanup(tmp);
    }

    tmp2 = _make_tmp();
    try {
        short = create_checkpoint(tmp2, [{"role": "user", "content": "  precise ask  "}], "p", "m");
        assert short["description"] == "precise ask";

        none_user = create_checkpoint(tmp2, [
            {"role": "system", "content": "sys"},
            {"role": "assistant", "content": "hi"},
        ], "p", "m", name="second-desc");
        assert none_user["description"] == "Empty conversation";

        empty = create_checkpoint(tmp2, [], "p", "m", name="third-desc");
        assert empty["description"] == "Empty conversation";
    } finally {
        _cleanup(tmp2);
    }
}


test "get_modified_files lists tracked edits and untracked files" {
    tmp = _make_tmp();
    try {
        repo = _init_git_repo(tmp);
        _write_file(repo, "base.txt", "base v2\n");
        _write_file(repo, "new.txt", "untracked\n");
        _write_file(repo, "nested/un.txt", "deep untracked\n");

        files = get_modified_files(repo);
        assert "base.txt" in files;
        assert "new.txt" in files;
        assert "nested/un.txt" in files;
        # Clean repo has nothing to snapshot.
        assert get_modified_files(tmp) == [];
    } finally {
        _cleanup(tmp);
    }
}


test "gitCommitHash matches HEAD inside a repo and is null outside" {
    tmp = _make_tmp();
    try {
        repo = _init_git_repo(tmp);
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo,
            capture_output=True, text=True, timeout=15,
        ).stdout.strip();
        meta = create_checkpoint(repo, [], "p", "m", name="in-repo");
        assert meta["gitCommitHash"] == head;

        plain = create_checkpoint(tmp, [], "p", "m", name="off-repo");
        assert plain["gitCommitHash"] is None;
    } finally {
        _cleanup(tmp);
    }
}


test "load round trips metadata, conversation and file snapshots" {
    tmp = _make_tmp();
    try {
        msgs = _msgs("round trip");
        _write_file(tmp, "a.txt", "content-a");
        create_checkpoint(
            tmp, msgs, "prov", "model-y", name="snap",
            modified_files=["a.txt"],
        );

        data = load_checkpoint(tmp, "snap");
        assert data["metadata"]["name"] == "snap";
        assert data["metadata"]["messageCount"] == len(msgs);
        assert data["conversation"] == {"messages": msgs};
        assert data["fileSnapshots"] == {"a.txt": "content-a"};
    } finally {
        _cleanup(tmp);
    }
}


test "load raises for unknown names and corrupt or missing store files" {
    tmp = _make_tmp();
    try {
        failed = False;
        try {
            load_checkpoint(tmp, "ghost");
        } except ValueError {
            failed = True;
        }
        assert failed;

        create_checkpoint(tmp, [], "p", "m", name="corrupt");
        cp = os.path.join(_cp_dir(tmp), "corrupt");
        _write_file(cp, "metadata.json", "{not json at all");
        failed = False;
        try {
            load_checkpoint(tmp, "corrupt");
        } except ValueError {
            failed = True;
        }
        assert failed;

        create_checkpoint(tmp, [], "p", "m", name="noconv");
        os.remove(os.path.join(_cp_dir(tmp), "noconv", "conversation.json"));
        failed = False;
        try {
            load_checkpoint(tmp, "noconv");
        } except OSError {
            failed = True;
        }
        assert failed;
    } finally {
        _cleanup(tmp);
    }
}


test "load skips snapshot files that vanished from disk" {
    tmp = _make_tmp();
    try {
        _write_file(tmp, "gone.txt", "was here");
        create_checkpoint(tmp, [], "p", "m", name="partial",
                          modified_files=["gone.txt"]);
        os.remove(os.path.join(_cp_dir(tmp), "partial", "files", "gone.txt"));
        data = load_checkpoint(tmp, "partial");
        assert data["fileSnapshots"] == {};
        assert data["metadata"]["filesChanged"] == ["gone.txt"];
    } finally {
        _cleanup(tmp);
    }
}


test "list orders newest first with sizes and skips junk entries" {
    tmp = _make_tmp();
    try {
        m1 = create_checkpoint(tmp, [], "p", "m", name="oldest");
        m2 = create_checkpoint(tmp, [], "p", "m", name="middle");
        m3 = create_checkpoint(tmp, [], "p", "m", name="newest");
        assert len({m1["timestamp"], m2["timestamp"], m3["timestamp"]}) == 3;

        # Junk: no metadata, corrupt metadata, and a plain file.
        os.makedirs(os.path.join(_cp_dir(tmp), "junk-empty"));
        junk_corrupt = os.path.join(_cp_dir(tmp), "junk-corrupt");
        os.makedirs(junk_corrupt);
        _write_file(junk_corrupt, "metadata.json", "}garbage{");
        _write_file(_cp_dir(tmp), "loose.txt", "ignored");

        items = list_checkpoints(tmp);
        assert [str(i["name"]) for i in items] == ["newest", "middle", "oldest"];
        for item in items {
            assert isinstance(item["sizeBytes"], int);
            assert item["sizeBytes"] > 0;
            assert item["metadata"]["name"] == item["name"];
        }

        empty = _make_tmp();
        try {
            assert list_checkpoints(empty) == [];
        } finally {
            _cleanup(empty);
        }
    } finally {
        _cleanup(tmp);
    }
}


test "delete removes the directory and unknown deletes raise" {
    tmp = _make_tmp();
    try {
        keep = create_checkpoint(tmp, [], "p", "m", name="keeper");
        create_checkpoint(tmp, [], "p", "m", name="goner");
        gone_dir = os.path.join(_cp_dir(tmp), "goner");
        assert os.path.isdir(gone_dir);

        delete_checkpoint(tmp, "goner");
        assert not os.path.exists(gone_dir);
        assert [str(i["name"]) for i in list_checkpoints(tmp)] == [str(keep["name"])];

        failed = False;
        try {
            delete_checkpoint(tmp, "goner");
        } except ValueError {
            failed = True;
        }
        assert failed;
        failed = False;
        try {
            delete_checkpoint(tmp, "never-existed");
        } except ValueError {
            failed = True;
        }
        assert failed;
    } finally {
        _cleanup(tmp);
    }
}


test "restore writes snapshots back including nested directories" {
    tmp = _make_tmp();
    try {
        restore_checkpoint_files(tmp, {
            "top.txt": "restored-top",
            "deep/nested/f.txt": "restored-deep",
        });
        assert _read_file(os.path.join(tmp, "top.txt")) == "restored-top";
        assert _read_file(os.path.join(tmp, "deep", "nested", "f.txt")) == "restored-deep";

        # Overwrites existing content wholesale.
        _write_file(tmp, "top.txt", "changed after snapshot");
        restore_checkpoint_files(tmp, {"top.txt": "snapshot-content"});
        assert _read_file(os.path.join(tmp, "top.txt")) == "snapshot-content";
    } finally {
        _cleanup(tmp);
    }
}


test "restore aggregates per-file failures into one RuntimeError" {
    tmp = _make_tmp();
    try {
        # "." resolves to cwd itself, which cannot be opened for writing.
        failed = False;
        try {
            restore_checkpoint_files(tmp, {".": "impossible"});
        } except RuntimeError as exc {
            failed = True;
            assert "Failed to restore some files" in str(exc);
            assert "." in str(exc);
        }
        assert failed;
    } finally {
        _cleanup(tmp);
    }
}


test "full git round trip: modify, snapshot, modify again, restore" {
    tmp = _make_tmp();
    try {
        repo = _init_git_repo(tmp);
        _write_file(repo, "base.txt", "base v2\n");          # tracked edit
        _write_file(repo, "extra.txt", "extra v1\n");        # untracked

        meta = create_checkpoint(repo, _msgs("save my work"), "prov", "model-z");
        assert "base.txt" in meta["filesChanged"];
        assert "extra.txt" in meta["filesChanged"];
        snap_dir = os.path.join(_cp_dir(repo), str(meta["name"]));
        assert _read_file(os.path.join(snap_dir, "files", "base.txt")) == "base v2\n";

        # Diverge the tree further after the snapshot.
        _write_file(repo, "base.txt", "base v3\n");
        _write_file(repo, "extra.txt", "extra v2\n");

        data = load_checkpoint(repo, str(meta["name"]));
        restore_checkpoint_files(repo, data["fileSnapshots"]);
        assert _read_file(os.path.join(repo, "base.txt")) == "base v2\n";
        assert _read_file(os.path.join(repo, "extra.txt")) == "extra v1\n";

        # The restored checkpoint still loads and lists afterwards.
        assert [str(i["name"]) for i in list_checkpoints(repo)] == [str(meta["name"])];
        delete_checkpoint(repo, str(meta["name"]));
        assert list_checkpoints(repo) == [];
    } finally {
        _cleanup(tmp);
    }
}


test "format_relative_time buckets deltas into humanized strings" {
    assert format_relative_time(_iso_ago(seconds=10)) == "just now";
    assert format_relative_time(_iso_ago(minutes=1)) == "1 min ago";
    assert format_relative_time(_iso_ago(minutes=5)) == "5 mins ago";
    assert format_relative_time(_iso_ago(minutes=90)) == "1 hr ago";
    assert format_relative_time(_iso_ago(hours=3)) == "3 hrs ago";
    assert format_relative_time(_iso_ago(days=3)) == "3 days ago";
    stamp = _iso_ago(days=400);
    assert format_relative_time(stamp)[:4] != "just";  # bare date fallback
    assert re.match(r"\d{4}-\d{2}-\d{2}$", format_relative_time(stamp)) is not None;
}


test "overlay rows render name, counts, time and size" {
    item = {
        "metadata": {
            "name": "my-cp",
            "timestamp": "2026-01-01T00:00:00+00:00",
            "messageCount": 4,
            "filesChanged": ["a", "b"],
        },
        "sizeBytes": 2048,
    };
    row = format_checkpoint_overlay_row(item);
    assert row.startswith("my-cp \u2014 4 msgs, 2 files \u2014 ");
    assert "(2KB)" in row;

    no_size = {"metadata": dict(item["metadata"]), "sizeBytes": None};
    assert "(?)" in format_checkpoint_overlay_row(no_size);
}


test "format_checkpoint_list prints header lines or the empty-state hint" {
    assert format_checkpoint_list([]) == "No checkpoints. Use /checkpoint create [name].";
    items = [{
        "metadata": {
            "name": "cp-1",
            "timestamp": "2026-01-01T12:30:45+00:00",
            "messageCount": 7,
            "filesChanged": ["x"],
        },
        "sizeBytes": 1024,
    }];
    out = format_checkpoint_list(items);
    assert out.startswith("Checkpoints:\n");
    assert "- cp-1 (2026-01-01 12:30, 7 msgs, 1 files, 1KB)" in out;
}
