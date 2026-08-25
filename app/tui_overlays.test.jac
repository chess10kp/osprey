"""Tasks/checkpoints overlay row builders for tui.jac.

tui.jac cannot be imported headless (its `with entry` TTY guard raises
SystemExit(1) under `jac test` — same constraint as keybinding_probe), so
this file REPLICATES the two pure picker-entry builders verbatim:
_task_picker_entries and _checkpoint_picker_entries (plus their _meter
dependency). Everything BEHIND them is real: agent.tasks.load_tasks /
task_counts / format_tasks_list and agent.checkpoints.list_checkpoints /
format_checkpoint_overlay_row run against a temp project dir.
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
