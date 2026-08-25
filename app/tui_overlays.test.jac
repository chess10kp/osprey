"""Tasks/checkpoints/explorer/skills overlay row builders for tui.jac.

tui.jac cannot be imported headless (its `with entry` TTY guard raises
SystemExit(1) under `jac test` — same constraint as keybinding_probe), so
this file REPLICATES the pure picker-entry builders verbatim:
_task_picker_entries, _checkpoint_picker_entries, plus the newer
_explorer_file_entries / _skills_picker_entries / _format_mentions wiring.
Everything BEHIND them is real: agent.tasks / agent.checkpoints /
agent.skills loaders (load_skills_from_dir) run against a temp project dir.
Keep the replicas in sync with app/tui.jac.
"""

import os;
import tempfile;
import shutil;
import json;

import from ui.width { display_width, truncate_text }
import from agent.tasks {
    load_tasks,
    format_tasks_list,
    task_counts,
    add_task,
}
import from agent.checkpoints {
    create_checkpoint,
    list_checkpoints,
    format_checkpoint_overlay_row,
}
import from agent.skills {
    load_skills_from_dir,
    _load_ignore_rules,
    _match_ignore_pattern,
}


# --- verbatim replica of tui.jac _meter ---------------------------------

def _meter(value: float, width: int) -> str {
    if width < 3 {
        return "▪" * max(0, width);
    }
    inner = width - 2;
    filled = int(max(0.0, min(1.0, value)) * float(inner));
    if filled > inner {
        filled = inner;
    }
    return "▐" + ("█" * filled) + ("░" * (inner - filled)) + "▌";
}


# --- verbatim replicas of tui.jac picker entry builders ------------------

def _task_picker_entries(cwd: str) -> dict {
    tasks = load_tasks(cwd);
    if not tasks {
        return {"rows": ["No tasks yet."], "ids": ["__header__"]};
    }
    counts = task_counts(tasks);
    total: int = int(counts["pending"]) + int(counts["in_progress"]) + int(counts["completed"]);
    ratio: float = float(counts["completed"]) / float(total) if total else 0.0;
    rows: list[str] = [
        str(total) + " tasks  " + _meter(ratio, 14) + "  "
        + str(counts["completed"]) + "/" + str(total) + " done"
    ];
    ids: list[str] = ["__header__"];
    idx = 0;
    for ln in format_tasks_list(tasks).split("\n") {
        rows.append(ln);
        # First two board lines are the counts header and divider rule;
        # everything after maps back onto its task index for enter.
        if idx >= 2 {
            ids.append(str(idx - 2));
        } else {
            ids.append("__header__");
        }
        idx += 1;
    }
    return {"rows": rows, "ids": ids};
}


def _checkpoint_picker_entries(cwd: str) -> dict {
    items = list_checkpoints(cwd);
    rows: list[str] = [];
    ids: list[str] = [];
    for item in items[:20] {
        rows.append(format_checkpoint_overlay_row(item));
        ids.append(str(item.get("name", "")));
    }
    return {"rows": rows, "ids": ids};
}


# --- verbatim replica of tui.jac explorer/skills builders -----------------

glob _EXPLORER_SKIP_DIRS: list[str] = [
         "node_modules", "__pycache__", ".git", ".jac", ".jackal",
         ".venv", "venv", ".mypy_cache", ".pytest_cache",
     ],
     _EXPLORER_MAX_FILES: int = 400,
     _EXPLORER_MAX_DEPTH: int = 6;


def _explorer_walk(dir_path: str, base_root: str, depth: int, out: list[str]) {
    if depth > _EXPLORER_MAX_DEPTH or len(out) >= _EXPLORER_MAX_FILES {
        return;
    }
    rules: list = [];
    try {
        rules = _load_ignore_rules(base_root, dir_path);
    } except Exception {
        rules = [];
    }
    try {
        entries = sorted(os.listdir(dir_path));
    } except OSError {
        return;
    }
    subdirs: list[str] = [];
    for name in entries {
        full = os.path.join(dir_path, name);
        is_dir = os.path.isdir(full);
        rel_fn: any = os.path.relpath;
        rel = str(rel_fn(full, base_root)).replace(os.sep, "/");
        # Ignore patterns match dirs with a trailing slash (skills.jac
        # convention), files bare.
        rel_cmp = rel + "/" if is_dir else rel;
        try {
            if _match_ignore_pattern(rel_cmp, rules) {
                continue;
            }
        } except Exception {
        }
        if is_dir {
            if name.startswith(".") or name in _EXPLORER_SKIP_DIRS {
                continue;
            }
            subdirs.append(name);
        } else {
            if len(out) < _EXPLORER_MAX_FILES {
                out.append(rel);
            }
        }
    }
    for name in subdirs {
        _explorer_walk(os.path.join(dir_path, name), base_root, depth + 1, out);
        if len(out) >= _EXPLORER_MAX_FILES {
            return;
        }
    }
}


def _explorer_file_entries(cwd: str) -> dict {
    out: list[str] = [];
    _explorer_walk(cwd, cwd, 1, out);
    return {"rows": list(out), "ids": list(out)};
}


def _skills_picker_entries(skills: list) -> dict {
    if not skills {
        return {"rows": ["no skills found"], "ids": ["__header__"]};
    }
    rows: list[str] = [];
    ids: list[str] = [];
    for s in skills {
        name = str(s.get("name", ""));
        desc = str(s.get("description", ""));
        label = name + (" — " + desc if desc else "");
        if s.get("disableModelInvocation", False) is True {
            label += "  · hidden";
        }
        rows.append(label);
        ids.append(name);
    }
    return {"rows": rows, "ids": ids};
}


def _format_mentions(paths: list) -> str {
    parts: list[str] = [];
    seen: set[str] = set();
    for p in paths {
        rel = str(p);
        if not rel or rel in seen {
            continue;
        }
        seen.add(rel);
        parts.append("@" + rel);
    }
    if not parts {
        return "";
    }
    return " ".join(parts) + " ";
}


# --- fixtures ------------------------------------------------------------

def _make_project -> str {
    return tempfile.mkdtemp(prefix="jackal-tui-overlays-");
}


def _seed_task_file(cwd: str, tasks: list) {
    os.makedirs(os.path.join(cwd, ".jackal"), exist_ok=True);
    fh = open(os.path.join(cwd, ".jackal", "tasks.json"), "w");
    json.dump(tasks, fh);
    fh.close();
}


# --- tests ----------------------------------------------------------------

test "empty project yields single non-selectable header row" {
    cwd = _make_project();
    try {
        entries = _task_picker_entries(cwd);
        assert entries["rows"] == ["No tasks yet."];
        assert entries["ids"] == ["__header__"];
        assert _checkpoint_picker_entries(cwd)["rows"] == [];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "task board maps selectable ids onto task indices" {
    cwd = _make_project();
    try {
        add_task(cwd, "first thing");
        add_task(cwd, "second thing", "with a blurb");
        # Mark the first completed via a raw rewrite (update_tasks not
        # imported to keep this fixture minimal).
        seeded: list = [];
        for i in range(len(load_tasks(cwd))) {
            t = dict(load_tasks(cwd)[i]);
            if i == 0 {
                t["status"] = "completed";
                t["completedAt"] = str(t.get("createdAt"));
            }
            seeded.append(t);
        }
        _seed_task_file(cwd, seeded);

        entries = _task_picker_entries(cwd);
        # summary + counts header + divider + one row per task
        assert len(entries["rows"]) == 3 + len(seeded);
        assert entries["ids"][0] == "__header__";
        assert entries["ids"][1] == "__header__";
        assert entries["ids"][2] == "__header__";
        assert entries["ids"][3] == "0";
        assert entries["ids"][4] == "1";
        # Meter summary reflects the one completed task.
        assert "█" in entries["rows"][0];
        assert "1/2 done" in entries["rows"][0];
        # Task rows carry the store's own formatting (icon, id, title).
        assert "✓" in entries["rows"][3];
        assert "second thing" in entries["rows"][4];
        assert "— with a blurb" in entries["rows"][4];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "checkpoint entries expose newest-first names with overlay rows" {
    cwd = _make_project();
    try {
        meta_old = create_checkpoint(
            cwd, [{"role": "user", "content": "hello"}],
            "mock", "mockllm", name="cp-old", modified_files=[],
        );
        meta_new = create_checkpoint(
            cwd, [], "mock", "mockllm", name="cp-new", modified_files=[],
        );
        assert meta_old["name"] == "cp-old";
        assert meta_new["name"] == "cp-new";

        entries = _checkpoint_picker_entries(cwd);
        assert len(entries["rows"]) == 2;
        # Newest timestamp first; ids map 1:1 onto picker actions.
        assert entries["ids"] == ["cp-new", "cp-old"];
        assert "cp-new" in entries["rows"][0];
        assert "0 msgs" in entries["rows"][0];
        assert "0 files" in entries["rows"][0];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}


def _touch(cwd: str, rel: str) {
    full = os.path.join(cwd, rel);
    parent = os.path.dirname(full);
    if parent {
        os.makedirs(parent, exist_ok=True);
    }
    fh = open(full, "w");
    fh.write("x");
    fh.close();
}


def _seed_skill(cwd: str, dir_name: str, name: str, description: str, hidden: bool = False) {
    sk_dir = os.path.join(cwd, ".jackal", "skills", dir_name);
    os.makedirs(sk_dir, exist_ok=True);
    fm = "---\nname: " + name + "\ndescription: " + description + "\n";
    if hidden {
        fm += "disable-model-invocation: true\n";
    }
    fm += "---\nBody.\n";
    fh = open(os.path.join(sk_dir, "SKILL.md"), "w");
    fh.write(fm);
    fh.close();
}


# --- explorer / skills / mention tests ------------------------------------

test "explorer walk skips junk dirs and honors gitignore" {
    cwd = _make_project();
    try {
        os.makedirs(os.path.join(cwd, "sub"));
        os.makedirs(os.path.join(cwd, "node_modules", "pkg"));
        os.makedirs(os.path.join(cwd, "__pycache__"));
        os.makedirs(os.path.join(cwd, ".git"));
        _touch(cwd, ".gitignore");
        _touch(cwd, ".hidden-file");
        _touch(cwd, "a.txt");
        _touch(cwd, "ignored.txt");
        _touch(cwd, os.path.join("sub", "b.py"));
        _touch(cwd, os.path.join("node_modules", "pkg", "x.js"));
        gh = open(os.path.join(cwd, ".gitignore"), "w");
        gh.write("ignored.txt\n");
        gh.close();

        entries = _explorer_file_entries(cwd);
        # Dot-FILES stay selectable; dot-dirs and skip-listed dirs do not;
        # gitignore'd files are excluded. ids map 1:1 onto rows.
        assert entries["rows"] == [".gitignore", ".hidden-file", "a.txt", "sub/b.py"];
        assert entries["ids"] == entries["rows"];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "explorer walk enforces depth and file caps" {
    cwd = _make_project();
    try {
        deep = "";
        for i in range(8) {
            deep = os.path.join(deep, "d" + str(i)) if deep else "d0";
            _touch(cwd, os.path.join(deep, "leaf.txt"));
        }
        for j in range(5) {
            _touch(cwd, "f" + str(j) + ".txt");
        }
        entries = _explorer_file_entries(cwd);
        # Depth cap (6): leaves under d0..d4 survive the walk (root=1,
        # d0=2 ... d4=6), d5+ branches are cut. Plus the 5 root files.
        assert len(entries["rows"]) == 10;
        for r in entries["rows"] {
            assert "d5" not in r and "d6" not in r;
        }
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "skills picker lists project skills with hidden tagging" {
    cwd = _make_project();
    try {
        entries = _skills_picker_entries([]);
        assert entries["rows"] == ["no skills found"];
        assert entries["ids"] == ["__header__"];

        _seed_skill(cwd, "my-skill", "my-skill", "does things well");
        _seed_skill(cwd, "quiet-skill", "quiet-skill", "hidden helper", hidden=True);

        # Real loader: parse the seeded project skills dir, then format.
        loaded: dict = load_skills_from_dir(
            os.path.join(cwd, ".jackal", "skills"), "project"
        );
        assert len(loaded["skills"]) == 2;

        entries = _skills_picker_entries(loaded["skills"]);
        # Name-sorted by the loader; ids are skill names so enter can
        # insert /skill:name.
        assert entries["ids"] == ["my-skill", "quiet-skill"];
        assert entries["rows"][0] == "my-skill — does things well";
        assert "quiet-skill — hidden helper" in entries["rows"][1];
        assert "· hidden" in entries["rows"][1];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "mention formatting dedupes and trails a space" {
    assert _format_mentions([]) == "";
    got = _format_mentions(["a.py", "sub/b.py", "a.py"]);
    assert got == "@a.py @sub/b.py ";
}
