// Agent task tools — create/update/list/delete backed by .jackal/tasks.json.

import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import {
  addTask,
  clearTasks,
  formatTaskLine,
  formatTasksList,
  loadTasks,
  removeTaskById,
  saveTasks,
  taskCounts,
  updateTasks,
  type Task,
  type TaskStatus,
} from "../workflow/tasks.js";

function formatAllTasksText(tasks: Task[], prefix: string): string {
  const counts = taskCounts(tasks);
  const allTasksList = tasks.map((t) => `  ${formatTaskLine(t)}`).join("\n");
  return `${prefix}\n\nAll Tasks (${counts.pending} pending, ${counts.in_progress} in progress, ${counts.completed} completed):\n${allTasksList || "(none)"}`;
}

export function createTaskTools(cwd: string): AgentTool[] {
  const createTaskTool: AgentTool = {
    name: "create_task",
    label: "Create Task",
    description:
      "Create one or more tasks to track work. Use for multi-step operations.",
    parameters: Type.Object({
      tasks: Type.Array(
        Type.Object({
          title: Type.String({ description: "Task title" }),
          description: Type.Optional(Type.String({ description: "Optional description" })),
        }),
      ),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as {
        tasks: Array<{ title: string; description?: string }>;
      };
      if (!params.tasks?.length) {
        throw new Error("At least one task is required");
      }

      const created: Task[] = [];
      for (const input of params.tasks) {
        const title = input.title?.trim();
        if (!title) throw new Error("Task title cannot be empty");
        if (title.length > 200) throw new Error("Task title is too long (max 200 characters)");
        created.push(await addTask(cwd, title, input.description));
      }

      const all = await loadTasks(cwd);
      const createdList = created.map((t) => `  ○ [${t.id}] ${t.title}`).join("\n");
      const text = formatAllTasksText(all, `Created ${created.length} task(s):\n${createdList}`);

      return {
        content: [{ type: "text", text }],
        details: { created, all },
      };
    },
  };

  const updateTaskTool: AgentTool = {
    name: "update_task",
    label: "Update Task",
    description:
      "Update tasks — mark in_progress when starting, completed when done.",
    parameters: Type.Object({
      updates: Type.Array(
        Type.Object({
          id: Type.String({ description: "Task ID" }),
          status: Type.Optional(
            Type.Union([
              Type.Literal("pending"),
              Type.Literal("in_progress"),
              Type.Literal("completed"),
            ]),
          ),
          title: Type.Optional(Type.String()),
          description: Type.Optional(Type.String()),
        }),
      ),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as {
        updates: Array<{
          id: string;
          status?: TaskStatus;
          title?: string;
          description?: string;
        }>;
      };
      if (!params.updates?.length) {
        throw new Error("At least one update is required");
      }

      const results: string[] = [];
      for (const update of params.updates) {
        if (!update.id?.trim()) throw new Error("Task ID is required");
        if (
          update.status === undefined &&
          update.title === undefined &&
          update.description === undefined
        ) {
          throw new Error("At least one field (status, title, description) must be provided");
        }
        if (update.title !== undefined && update.title.trim().length === 0) {
          throw new Error("Task title cannot be empty");
        }
      }

      const before = await loadTasks(cwd);
      const all = await updateTasks(cwd, params.updates);

      for (const update of params.updates) {
        const task = all.find((t) => t.id === update.id);
        if (!task) {
          results.push(`  ✗ Task not found: ${update.id}`);
          continue;
        }
        results.push(`  ${formatTaskLine(task)}`);
      }

      const text = formatAllTasksText(all, `Updated ${params.updates.length} task(s):\n${results.join("\n")}`);
      return {
        content: [{ type: "text", text }],
        details: { before, all },
      };
    },
  };

  const listTasksTool: AgentTool = {
    name: "list_tasks",
    label: "List Tasks",
    description: "List tasks with optional status filter.",
    parameters: Type.Object({
      status: Type.Optional(
        Type.Union([
          Type.Literal("pending"),
          Type.Literal("in_progress"),
          Type.Literal("completed"),
          Type.Literal("all"),
        ]),
      ),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { status?: TaskStatus | "all" };
      const all = await loadTasks(cwd);
      const filter = params.status ?? "all";
      const filtered =
        filter === "all" ? all : all.filter((t) => t.status === filter);

      if (filtered.length === 0) {
        const text =
          filter === "all"
            ? "No tasks found. Create one with create_task."
            : `No tasks with status "${filter}" found.`;
        return { content: [{ type: "text", text }], details: { tasks: filtered } };
      }

      const text = formatTasksList(
        filtered,
        filter === "all" ? "Tasks" : `Tasks (${filter} only)`,
      );
      return { content: [{ type: "text", text }], details: { tasks: filtered, all } };
    },
  };

  const deleteTaskTool: AgentTool = {
    name: "delete_task",
    label: "Delete Task",
    description: "Delete tasks by ID or clear all tasks.",
    parameters: Type.Object({
      ids: Type.Optional(Type.Array(Type.String({ description: "Task IDs to delete" }))),
      clear_all: Type.Optional(Type.Boolean({ description: "Clear all tasks" })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { ids?: string[]; clear_all?: boolean };
      const hasIds = Boolean(params.ids?.length);
      const hasClearAll = params.clear_all === true;

      if (!hasIds && !hasClearAll) {
        throw new Error("Either ids or clear_all must be provided");
      }
      if (hasIds && hasClearAll) {
        throw new Error("Cannot specify both ids and clear_all");
      }

      if (hasClearAll) {
        const before = await loadTasks(cwd);
        await clearTasks(cwd);
        const text = `Cleared all ${before.length} task(s)\n\nNo tasks remaining.`;
        return { content: [{ type: "text", text }], details: { cleared: before.length } };
      }

      const tasks = await loadTasks(cwd);
      const results: string[] = [];
      const idsToDelete = new Set(params.ids);
      const remaining = tasks.filter((t) => {
        if (idsToDelete.has(t.id)) {
          results.push(`  ✗ [${t.id}] ${t.title}`);
          return false;
        }
        return true;
      });

      const foundIds = new Set(tasks.map((t) => t.id));
      for (const id of params.ids ?? []) {
        if (!foundIds.has(id)) {
          results.push(`  ? Task not found: ${id}`);
        }
      }

      await saveTasks(cwd, remaining);

      const text =
        remaining.length === 0
          ? `Deleted ${params.ids!.length} task(s):\n${results.join("\n")}\n\nNo tasks remaining.`
          : formatAllTasksText(
              remaining,
              `Deleted ${params.ids!.length} task(s):\n${results.join("\n")}`,
            );

      return {
        content: [{ type: "text", text }],
        details: { deleted: params.ids, remaining },
      };
    },
  };

  return [createTaskTool, updateTaskTool, listTasksTool, deleteTaskTool];
}
