// Task store — persist multi-step work under .jackal/tasks.json.
// I/O delegated to lib/jac/workflow/_tasks_toolchain.py via bridge.

import {
  bridgeLoadTasks,
  bridgeSaveTasks,
  bridgeClearTasks,
  bridgeAddTask,
  bridgeRemoveTaskByIndex,
  bridgeRemoveTaskById,
  bridgeUpdateTasks,
  bridgeTaskCounts,
  bridgeFormatTaskLine,
  bridgeFormatTasksList,
  bridgeTasksPath,
  bridgeGenerateTaskId,
  type BridgeTask,
} from "../jac/jac-bridge.js";

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

function fromBridge(t: BridgeTask): Task {
  return {
    id: t.id,
    title: t.title,
    description: t.description ?? undefined,
    status: t.status as TaskStatus,
    createdAt: t.createdAt,
    updatedAt: t.updatedAt,
    completedAt: t.completedAt ?? undefined,
  };
}

export function tasksPath(cwd: string): string {
  return bridgeTasksPath(cwd);
}

export function generateTaskId(): string {
  return bridgeGenerateTaskId();
}

export async function loadTasks(cwd: string): Promise<Task[]> {
  return (await bridgeLoadTasks(cwd)).map(fromBridge);
}

export async function saveTasks(cwd: string, tasks: Task[]): Promise<void> {
  await bridgeSaveTasks(
    cwd,
    tasks.map((t) => ({
      id: t.id,
      title: t.title,
      description: t.description ?? null,
      status: t.status,
      createdAt: t.createdAt,
      updatedAt: t.updatedAt,
      completedAt: t.completedAt ?? null,
    })),
  );
}

export async function clearTasks(cwd: string): Promise<void> {
  await bridgeClearTasks(cwd);
}

export async function addTask(
  cwd: string,
  title: string,
  description?: string,
): Promise<Task> {
  return fromBridge(await bridgeAddTask(cwd, title, description));
}

export async function removeTaskByIndex(cwd: string, index: number): Promise<Task | null> {
  const t = await bridgeRemoveTaskByIndex(cwd, index);
  return t ? fromBridge(t) : null;
}

export async function removeTaskById(cwd: string, id: string): Promise<Task | null> {
  const t = await bridgeRemoveTaskById(cwd, id);
  return t ? fromBridge(t) : null;
}

export async function updateTasks(cwd: string, updates: TaskUpdate[]): Promise<Task[]> {
  return (await bridgeUpdateTasks(
    cwd,
    updates.map((u) => ({
      id: u.id,
      status: u.status,
      title: u.title,
      description: u.description,
    })),
  )).map(fromBridge);
}

export function taskCounts(tasks: Task[]): {
  pending: number;
  in_progress: number;
  completed: number;
} {
  return bridgeTaskCounts(
    tasks.map((t) => ({
      id: t.id,
      title: t.title,
      description: t.description ?? null,
      status: t.status,
      createdAt: t.createdAt,
      updatedAt: t.updatedAt,
      completedAt: t.completedAt ?? null,
    })),
  );
}

export function formatTaskLine(task: Task): string {
  return bridgeFormatTaskLine({
    id: task.id,
    title: task.title,
    description: task.description ?? null,
    status: task.status,
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
    completedAt: task.completedAt ?? null,
  });
}

export function formatTasksList(tasks: Task[], title = "Tasks"): string {
  return bridgeFormatTasksList(
    tasks.map((t) => ({
      id: t.id,
      title: t.title,
      description: t.description ?? null,
      status: t.status,
      createdAt: t.createdAt,
      updatedAt: t.updatedAt,
      completedAt: t.completedAt ?? null,
    })),
    title,
  );
}
