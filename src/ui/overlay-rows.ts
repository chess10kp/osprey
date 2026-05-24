// Row formatting for task/checkpoint Ink overlays.

import type { Task, TaskStatus } from "../workflow/tasks.js";
import { taskCounts } from "../workflow/tasks.js";

const STATUS_ICONS: Record<TaskStatus, string> = {
  pending: "○",
  in_progress: "◐",
  completed: "✓",
};

export function taskStatusIcon(status: TaskStatus): string {
  return STATUS_ICONS[status] ?? "○";
}

export function formatTaskOverlayRow(task: Task, index: number): string {
  const icon = taskStatusIcon(task.status);
  const desc = task.description ? ` — ${task.description}` : "";
  return `${icon} ${index + 1}. ${task.title}${desc}`;
}

export function formatTasksOverlayHeader(tasks: Task[]): string {
  if (tasks.length === 0) return "No tasks";
  const counts = taskCounts(tasks);
  return `${tasks.length} task(s) — ${counts.pending} pending, ${counts.in_progress} in progress, ${counts.completed} done`;
}
