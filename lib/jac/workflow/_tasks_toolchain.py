"""Task store — persist multi-step work under .jackal/tasks.json."""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path


TASKS_FILE = "tasks.json"


def tasks_path(cwd: str) -> str:
    return os.path.join(cwd, ".jackal", TASKS_FILE)


def generate_task_id() -> str:
    return uuid.uuid4().hex[:8]


def _tasks_dir(cwd: str) -> str:
    return os.path.join(cwd, ".jackal")


def _is_task(value: dict) -> bool:
    return (
        isinstance(value.get("id"), str)
        and isinstance(value.get("title"), str)
        and isinstance(value.get("status"), str)
        and isinstance(value.get("createdAt"), str)
        and isinstance(value.get("updatedAt"), str)
    )


def load_tasks(cwd: str) -> list[dict]:
    path = tasks_path(cwd)
    try:
        content = Path(path).read_text(encoding="utf-8")
        parsed = json.loads(content)
        if not isinstance(parsed, list):
            return []
        return [t for t in parsed if isinstance(t, dict) and _is_task(t)]
    except (OSError, json.JSONDecodeError):
        return []


def save_tasks(cwd: str, tasks: list[dict]) -> None:
    dir_path = _tasks_dir(cwd)
    os.makedirs(dir_path, exist_ok=True)
    Path(tasks_path(cwd)).write_text(
        json.dumps(tasks, indent=2) + "\n", encoding="utf-8"
    )


def clear_tasks(cwd: str) -> None:
    save_tasks(cwd, [])


def add_task(cwd: str, title: str, description: str | None = None) -> dict:
    tasks = load_tasks(cwd)
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc).isoformat()
    task = {
        "id": generate_task_id(),
        "title": title.strip(),
        "description": (description or "").strip() or None,
        "status": "pending",
        "createdAt": now,
        "updatedAt": now,
    }
    tasks.append(task)
    save_tasks(cwd, tasks)
    return task


def remove_task_by_index(cwd: str, index: int) -> dict | None:
    tasks = load_tasks(cwd)
    if index < 0 or index >= len(tasks):
        return None
    removed = tasks.pop(index)
    save_tasks(cwd, tasks)
    return removed


def remove_task_by_id(cwd: str, task_id: str) -> dict | None:
    tasks = load_tasks(cwd)
    idx = next((i for i, t in enumerate(tasks) if t["id"] == task_id), -1)
    if idx < 0:
        return None
    removed = tasks.pop(idx)
    save_tasks(cwd, tasks)
    return removed


def update_tasks(cwd: str, updates: list[dict]) -> list[dict]:
    tasks = load_tasks(cwd)
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc).isoformat()

    for update in updates:
        idx = next((i for i, t in enumerate(tasks) if t["id"] == update.get("id")), -1)
        if idx < 0:
            continue

        task = {**tasks[idx]}

        if "status" in update:
            task["status"] = update["status"]
            task["completedAt"] = now if update["status"] == "completed" else None
        if "title" in update:
            task["title"] = update["title"]
        if "description" in update:
            task["description"] = update["description"]
        task["updatedAt"] = now
        tasks[idx] = task

    save_tasks(cwd, tasks)
    return tasks


def task_counts(tasks: list[dict]) -> dict:
    return {
        "pending": sum(1 for t in tasks if t.get("status") == "pending"),
        "in_progress": sum(1 for t in tasks if t.get("status") == "in_progress"),
        "completed": sum(1 for t in tasks if t.get("status") == "completed"),
    }


def format_task_line(task: dict) -> str:
    icon = "✓" if task["status"] == "completed" else "◐" if task["status"] == "in_progress" else "○"
    desc = f" — {task['description']}" if task.get("description") else ""
    return f"{icon} [{task['id']}] {task['title']}{desc}"


def format_tasks_list(tasks: list[dict], title: str = "Tasks") -> str:
    if not tasks:
        return "No tasks. Use /tasks add <title> or create_task."

    counts = task_counts(tasks)
    header = f"{title} ({counts['pending']} pending, {counts['in_progress']} in progress, {counts['completed']} completed)"
    lines = [f"{i + 1}. {format_task_line(t)}" for i, t in enumerate(tasks)]
    return f"{header}\n{'─' * 50}\n" + "\n".join(lines)
