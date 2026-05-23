// Task store — persist multi-step work under .jackal/tasks.json.

import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

export type TaskStatus = "pending" | "in_progress" | "completed";

export interface Task {
  id: string;
  title: string;
  description?: string;
  status: TaskStatus;
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
}

export interface TaskUpdate {
  id: string;
  status?: TaskStatus;
  title?: string;
  description?: string;
}

const TASKS_FILE = "tasks.json";

export function tasksPath(cwd: string): string {
  return join(cwd, ".jackal", TASKS_FILE);
}

export function generateTaskId(): string {
  return randomUUID().slice(0, 8);
}

export async function loadTasks(cwd: string): Promise<Task[]> {
  try {
    const content = await readFile(tasksPath(cwd), "utf-8");
    const parsed = JSON.parse(content) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isTask);
  } catch {
    return [];
  }
}

export async function saveTasks(cwd: string, tasks: Task[]): Promise<void> {
  const dir = join(cwd, ".jackal");
  await mkdir(dir, { recursive: true });
  await writeFile(tasksPath(cwd), JSON.stringify(tasks, null, 2) + "\n", "utf-8");
}

export async function clearTasks(cwd: string): Promise<void> {
  await saveTasks(cwd, []);
}

export async function addTask(
  cwd: string,
  title: string,
  description?: string,
): Promise<Task> {
  const tasks = await loadTasks(cwd);
  const now = new Date().toISOString();
  const task: Task = {
    id: generateTaskId(),
    title: title.trim(),
    description: description?.trim() || undefined,
    status: "pending",
    createdAt: now,
    updatedAt: now,
  };
  tasks.push(task);
  await saveTasks(cwd, tasks);
  return task;
}

export async function removeTaskByIndex(cwd: string, index: number): Promise<Task | null> {
  const tasks = await loadTasks(cwd);
  if (index < 0 || index >= tasks.length) return null;
  const [removed] = tasks.splice(index, 1);
  await saveTasks(cwd, tasks);
  return removed ?? null;
}

export async function removeTaskById(cwd: string, id: string): Promise<Task | null> {
  const tasks = await loadTasks(cwd);
  const idx = tasks.findIndex((t) => t.id === id);
  if (idx < 0) return null;
  const [removed] = tasks.splice(idx, 1);
  await saveTasks(cwd, tasks);
  return removed ?? null;
}

export async function updateTasks(cwd: string, updates: TaskUpdate[]): Promise<Task[]> {
  const tasks = await loadTasks(cwd);
  const now = new Date().toISOString();

  for (const update of updates) {
    const idx = tasks.findIndex((t) => t.id === update.id);
    if (idx < 0) continue;

    const task = { ...tasks[idx]! };

    if (update.status !== undefined) {
      task.status = update.status;
      task.completedAt = update.status === "completed" ? now : undefined;
    }
    if (update.title !== undefined) {
      task.title = update.title;
    }
    if (update.description !== undefined) {
      task.description = update.description;
    }
    task.updatedAt = now;
    tasks[idx] = task;
  }

  await saveTasks(cwd, tasks);
  return tasks;
}

export function taskCounts(tasks: Task[]): {
  pending: number;
  in_progress: number;
  completed: number;
} {
  return {
    pending: tasks.filter((t) => t.status === "pending").length,
    in_progress: tasks.filter((t) => t.status === "in_progress").length,
    completed: tasks.filter((t) => t.status === "completed").length,
  };
}

export function formatTaskLine(task: Task): string {
  const icon =
    task.status === "completed" ? "✓" : task.status === "in_progress" ? "◐" : "○";
  const desc = task.description ? ` — ${task.description}` : "";
  return `${icon} [${task.id}] ${task.title}${desc}`;
}

export function formatTasksList(tasks: Task[], title = "Tasks"): string {
  if (tasks.length === 0) {
    return "No tasks. Use /tasks add <title> or create_task.";
  }

  const counts = taskCounts(tasks);
  const header = `${title} (${counts.pending} pending, ${counts.in_progress} in progress, ${counts.completed} completed)`;
  const lines = tasks.map((t, i) => `${i + 1}. ${formatTaskLine(t)}`);
  return `${header}\n${"─".repeat(50)}\n${lines.join("\n")}`;
}

function isTask(value: unknown): value is Task {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.id === "string" &&
    typeof v.title === "string" &&
    typeof v.status === "string" &&
    typeof v.createdAt === "string" &&
    typeof v.updatedAt === "string"
  );
}
