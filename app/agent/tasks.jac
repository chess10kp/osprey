"""Task store — persist multi-step work under .jackal/tasks.json (ported
from lib/jac/workflow/_tasks_toolchain.py, the Python source of truth;
the TS mirror src/workflow/tasks.ts is bridge-only and adds no behavior).

Persistence format (identical to the legacy runtime):
- Single file `<cwd>/.jackal/tasks.json` holding one JSON array of task
  dicts, written indent=2 with a trailing newline.
- Each task: {id, title, description, status, createdAt, updatedAt} plus
  optional completedAt once a status has ever been set via update_tasks.
  Keys are camelCase; description is None (null) when blank.
- Ids are 8 lowercase hex chars (uuid4 prefix). Uniqueness is NOT enforced,
  matching the legacy toolchain; lookups take the first match.
- Timestamps are ISO 8601 UTC from datetime.now(timezone.utc).isoformat()
  (e.g. 2026-05-23T13:38:24.261023+00:00) -- byte-compatible with what the
  Python toolchain writes.

Semantics preserved exactly: load filters entries lacking any required
string field; every mutating op is read-modify-write of the whole array;
update_tasks skips unknown ids and stamps updatedAt on every matched task;
setting status always refreshes completedAt (now when "completed",
otherwise None); remove by index/id return None when not found; clear
writes an empty array rather than deleting the file.

Deliberate deviations: none functional. datetime/uuid are imported at
module top instead of inside functions (the legacy code deferred them),
and helpers take no implicit globals beyond the two constants below.
"""

import os;
import json;
import uuid;
import datetime;

glob TASKS_FILE: str = "tasks.json",
     _NO_TASKS_LINE: str = "No tasks. Use /tasks add <title> or create_task.";


def tasks_path(cwd: str) -> str {
    return os.path.join(cwd, ".jackal", TASKS_FILE);
}


"""Fresh 8-hex-char task id (uuid4 prefix, like the legacy toolchain)."""
def generate_task_id() -> str {
    return uuid.uuid4().hex[:8];
}


def _now_iso() -> str {
    return datetime.datetime.now(datetime.timezone.utc).isoformat();
}


"""Required-field shape check; extra fields are tolerated."""
def _is_task(value: any) -> bool {
    return (
        isinstance(value, dict)
        and isinstance(value.get("id"), str)
        and isinstance(value.get("title"), str)
        and isinstance(value.get("status"), str)
        and isinstance(value.get("createdAt"), str)
        and isinstance(value.get("updatedAt"), str)
    );
}


"""All valid tasks from tasks.json; [] when missing, corrupt, or not a
list (invalid entries are filtered out rather than failing the load)."""
def load_tasks(cwd: str) -> list {
    fh = None;
    try {
        fh = open(tasks_path(cwd), "r");
        parsed = json.load(fh);
    } except (OSError, ValueError) {
        return [];
    } finally {
        if fh is not None {
            fh.close();
        }
    }
    if not isinstance(parsed, list) {
        return [];
    }
    valid: list = [];
    for item in parsed {
        if _is_task(item) {
            valid.append(item);
        }
    }
    return valid;
}


"""Persist the full task array (indent=2 + trailing newline), creating
the .jackal directory when needed."""
def save_tasks(cwd: str, tasks: list) -> bool {
    try {
        os.makedirs(os.path.join(cwd, ".jackal"), exist_ok=True);
    } except OSError {
        return False;
    }
    fh = None;
    try {
        fh = open(tasks_path(cwd), "w");
        json.dump(tasks, fh, indent=2);
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


"""Empty the store (writes [], never deletes the file)."""
def clear_tasks(cwd: str) -> bool {
    return save_tasks(cwd, []);
}


"""Append a new pending task; title is stripped, a blank description
becomes null. Returns the created task dict."""
def add_task(cwd: str, title: str, description: str = "") -> dict {
    tasks = load_tasks(cwd);
    now = _now_iso();
    trimmed_desc = (description or "").strip();
    task: dict = {
        "id": generate_task_id(),
        "title": title.strip(),
        "description": trimmed_desc if trimmed_desc else None,
        "status": "pending",
        "createdAt": now,
        "updatedAt": now,
    };
    tasks.append(task);
    save_tasks(cwd, tasks);
    return task;
}


"""Remove the task at `index`; None when out of range."""
def remove_task_by_index(cwd: str, index: int) -> dict | None {
    tasks = load_tasks(cwd);
    if index < 0 or index >= len(tasks) {
        return None;
    }
    removed = tasks.pop(index);
    save_tasks(cwd, tasks);
    return removed;
}


"""Remove the first task whose id matches; None when unknown."""
def remove_task_by_id(cwd: str, task_id: str) -> dict | None {
    tasks = load_tasks(cwd);
    idx: int = -1;
    pos: int = 0;
    while pos < len(tasks) {
        if str(tasks[pos]["id"]) == task_id {
            idx = pos;
            break;
        }
        pos += 1;
    }
    if idx < 0 {
        return None;
    }
    removed = tasks.pop(idx);
    save_tasks(cwd, tasks);
    return removed;
}


"""Apply {id, status?, title?, description?} updates to matching tasks.

Unknown ids are skipped silently. A matched task gets updatedAt refreshed;
a status change also rewrites completedAt (now for "completed", else null).
Returns the full post-update task list.
"""
def update_tasks(cwd: str, updates: list) -> list {
    tasks = load_tasks(cwd);
    now = _now_iso();
    for update in updates {
        if not isinstance(update, dict) {
            continue;
        }
        idx: int = -1;
        pos: int = 0;
        while pos < len(tasks) {
            if str(tasks[pos]["id"]) == str(update.get("id")) {
                idx = pos;
                break;
            }
            pos += 1;
        }
        if idx < 0 {
            continue;
        }
        task: dict = dict(tasks[idx]);
        if "status" in update {
            task["status"] = update["status"];
            if update["status"] == "completed" {
                task["completedAt"] = now;
            } else {
                task["completedAt"] = None;
            }
        }
        if "title" in update {
            task["title"] = update["title"];
        }
        if "description" in update {
            task["description"] = update["description"];
        }
        task["updatedAt"] = now;
        tasks[idx] = task;
    }
    save_tasks(cwd, tasks);
    return tasks;
}


"""Counts keyed by legacy snake_case status names."""
def task_counts(tasks: list) -> dict {
    pending: int = 0;
    in_progress: int = 0;
    completed: int = 0;
    for t in tasks {
        status = str(t.get("status", ""));
        if status == "pending" {
            pending += 1;
        } elif status == "in_progress" {
            in_progress += 1;
        } elif status == "completed" {
            completed += 1;
        }
    }
    return {"pending": pending, "in_progress": in_progress, "completed": completed};
}


"""One rendered row: status icon, [id], title, optional em-dash blurb."""
def format_task_line(task: dict) -> str {
    icon: str = "○";
    status = str(task.get("status", ""));
    if status == "completed" {
        icon = "✓";
    } elif status == "in_progress" {
        icon = "◐";
    }
    desc = task.get("description");
    suffix: str = "";
    if isinstance(desc, str) and desc {
        suffix = " — " + desc;
    }
    return icon + " [" + str(task["id"]) + "] " + str(task["title"]) + suffix;
}


"""Rendered board: counts header, divider, numbered rows (or a hint when
the list is empty)."""
def format_tasks_list(tasks: list, title: str = "Tasks") -> str {
    if not tasks {
        return _NO_TASKS_LINE;
    }
    counts = task_counts(tasks);
    header = (
        title
        + " (" + str(counts["pending"]) + " pending"
        + ", " + str(counts["in_progress"]) + " in progress"
        + ", " + str(counts["completed"]) + " completed)"
    );
    lines: list[str] = [];
    idx: int = 0;
    while idx < len(tasks) {
        lines.append(str(idx + 1) + ". " + format_task_line(tasks[idx]));
        idx += 1;
    }
    return header + "\n" + ("─" * 50) + "\n" + "\n".join(lines);
}
