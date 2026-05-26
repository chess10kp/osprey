"""Overlay row formatting for task/checkpoint Ink overlays."""

from __future__ import annotations

_STATUS_ICONS = {
    "pending": "○",
    "in_progress": "◐",
    "completed": "✓",
}


def task_status_icon(status: str) -> str:
    return _STATUS_ICONS.get(status, "○")


def format_task_overlay_row(task: dict, index: int) -> str:
    icon = task_status_icon(task.get("status", "pending"))
    desc = f" — {task['description']}" if task.get("description") else ""
    return f"{icon} {index + 1}. {task['title']}{desc}"


def _task_counts(tasks: list[dict]) -> dict:
    return {
        "pending": sum(1 for t in tasks if t.get("status") == "pending"),
        "in_progress": sum(1 for t in tasks if t.get("status") == "in_progress"),
        "completed": sum(1 for t in tasks if t.get("status") == "completed"),
    }


def format_tasks_overlay_header(tasks: list[dict]) -> str:
    if not tasks:
        return "No tasks"
    counts = _task_counts(tasks)
    return f"{len(tasks)} task(s) — {counts['pending']} pending, {counts['in_progress']} in progress, {counts['completed']} done"
