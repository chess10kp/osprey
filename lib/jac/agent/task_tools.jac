"""Task tool helpers — validation, formatting, result building for agent task tools."""

::py::
import os
import sys as _sys

_task_dir = os.path.join(os.getcwd(), "lib", "jac", "workflow")
if _task_dir not in _sys.path:
    _sys.path.insert(0, _task_dir)

from _tasks_toolchain import (
    load_tasks,
    save_tasks,
    clear_tasks,
    add_task,
    update_tasks,
    task_counts,
    format_task_line,
    format_tasks_list,
)


def _format_all_tasks_text(tasks, prefix):
    counts = task_counts(tasks)
    lines = [f"  {format_task_line(t)}" for t in tasks]
    all_text = "\n".join(lines) or "(none)"
    return (
        f"{prefix}\n\n"
        f"All Tasks ({counts['pending']} pending, {counts['in_progress']} in progress, "
        f"{counts['completed']} completed):\n{all_text}"
    )


def validate_create_tasks(params):
    tasks_input = params.get("tasks", [])
    if not tasks_input:
        raise ValueError("At least one task is required")
    created = []
    for inp in tasks_input:
        title = (inp.get("title") or "").strip()
        if not title:
            raise ValueError("Task title cannot be empty")
        if len(title) > 200:
            raise ValueError("Task title is too long (max 200 characters)")
        created.append({"title": title, "description": inp.get("description")})
    return created


def validate_update_tasks(params):
    updates = params.get("updates", [])
    if not updates:
        raise ValueError("At least one update is required")
    for u in updates:
        if not (u.get("id") or "").strip():
            raise ValueError("Task ID is required")
        if (
            u.get("status") is None
            and u.get("title") is None
            and u.get("description") is None
        ):
            raise ValueError("At least one field (status, title, description) must be provided")
        if u.get("title") is not None and not u["title"].strip():
            raise ValueError("Task title cannot be empty")
    return updates


def validate_delete_tasks(params):
    has_ids = bool(params.get("ids"))
    has_clear = params.get("clear_all") is True
    if not has_ids and not has_clear:
        raise ValueError("Either ids or clear_all must be provided")
    if has_ids and has_clear:
        raise ValueError("Cannot specify both ids and clear_all")
    return {"has_ids": has_ids, "has_clear": has_clear}


def build_create_result(cwd, created_inputs):
    created = []
    for inp in created_inputs:
        task = add_task(cwd, inp["title"], inp.get("description"))
        created.append(task)
    all_tasks = load_tasks(cwd)
    created_lines = [f"  ○ [{t['id']}] {t['title']}" for t in created]
    header = f"Created {len(created)} task(s):\n" + "\n".join(created_lines)
    text = _format_all_tasks_text(all_tasks, header)
    return {"text": text, "created": created, "all": all_tasks}


def build_update_result(cwd, updates):
    all_tasks = update_tasks(cwd, updates)
    results = []
    for u in updates:
        task = next((t for t in all_tasks if t["id"] == u["id"]), None)
        if not task:
            results.append(f"  ✗ Task not found: {u['id']}")
        else:
            results.append(f"  {format_task_line(task)}")
    header = f"Updated {len(updates)} task(s):\n" + "\n".join(results)
    text = _format_all_tasks_text(all_tasks, header)
    return {"text": text, "all": all_tasks}


def build_list_result(cwd, status_filter="all"):
    all_tasks = load_tasks(cwd)
    filtered = all_tasks if status_filter == "all" else [t for t in all_tasks if t["status"] == status_filter]
    if not filtered:
        text = (
            "No tasks found. Create one with create_task."
            if status_filter == "all"
            else f'No tasks with status "{status_filter}" found.'
        )
    else:
        text = format_tasks_list(
            filtered,
            "Tasks" if status_filter == "all" else f"Tasks ({status_filter} only)",
        )
    return {"text": text, "tasks": filtered, "all": all_tasks}


def build_delete_result(cwd, params):
    validation = validate_delete_tasks(params)
    if validation["has_clear"]:
        before = load_tasks(cwd)
        clear_tasks(cwd)
        text = f"Cleared all {len(before)} task(s)\n\nNo tasks remaining."
        return {"text": text, "cleared": len(before)}

    ids_to_delete = set(params.get("ids", []))
    tasks = load_tasks(cwd)
    results = []
    remaining = []
    for t in tasks:
        if t["id"] in ids_to_delete:
            results.append(f"  ✗ [{t['id']}] {t['title']}")
        else:
            remaining.append(t)
    found_ids = {t["id"] for t in tasks}
    for tid in params.get("ids", []):
        if tid not in found_ids:
            results.append(f"  ? Task not found: {tid}")

    save_tasks(cwd, remaining)
    ids_list = params.get("ids", [])
    if not remaining:
        text = f"Deleted {len(ids_list)} task(s):\n" + "\n".join(results) + "\n\nNo tasks remaining."
    else:
        header = f"Deleted {len(ids_list)} task(s):\n" + "\n".join(results)
        text = _format_all_tasks_text(remaining, header)
    return {"text": text, "deleted": ids_list, "remaining": remaining}
::py::

test "validate create empty" {
    try {
        validate_create_tasks({"tasks": []});
        assert False;
    } except ValueError as e {
        assert "At least one" in str(e);
    }
}

test "validate create empty title" {
    try {
        validate_create_tasks({"tasks": [{"title": ""}]});
        assert False;
    } except ValueError as e {
        assert "cannot be empty" in str(e);
    }
}

test "validate create long title" {
    try {
        validate_create_tasks({"tasks": [{"title": "x" * 201}]});
        assert False;
    } except ValueError as e {
        assert "too long" in str(e);
    }
}

test "validate create valid" {
    result = validate_create_tasks({"tasks": [{"title": "My task", "description": "desc"}]});
    assert len(list(result)) == 1;
    assert result[0]["title"] == "My task";
}

test "validate update empty" {
    try {
        validate_update_tasks({"updates": []});
        assert False;
    } except ValueError as e {
        assert "At least one" in str(e);
    }
}

test "validate update no id" {
    try {
        validate_update_tasks({"updates": [{"status": "completed"}]});
        assert False;
    } except ValueError as e {
        assert "Task ID is required" in str(e);
    }
}

test "validate update no fields" {
    try {
        validate_update_tasks({"updates": [{"id": "abc"}]});
        assert False;
    } except ValueError as e {
        assert "At least one field" in str(e);
    }
}

test "validate delete neither" {
    try {
        validate_delete_tasks({});
        assert False;
    } except ValueError as e {
        assert "Either ids or clear_all" in str(e);
    }
}

test "validate delete both" {
    try {
        validate_delete_tasks({"ids": ["a"], "clear_all": True});
        assert False;
    } except ValueError as e {
        assert "Cannot specify both" in str(e);
    }
}
