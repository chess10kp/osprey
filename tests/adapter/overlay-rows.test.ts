import { describe, expect, it } from "vitest";
import { formatCheckpointOverlayRow, formatRelativeTime } from "../../src/workflow/checkpoints.js";
import {
  formatTaskOverlayRow,
  formatTasksOverlayHeader,
  taskStatusIcon,
} from "../../src/ui/overlay-rows.js";
import type { Task } from "../../src/workflow/tasks.js";

describe("overlay row formatting", () => {
  it("formats task status icons", () => {
    expect(taskStatusIcon("pending")).toBe("○");
    expect(taskStatusIcon("in_progress")).toBe("◐");
    expect(taskStatusIcon("completed")).toBe("✓");
  });

  it("formats task overlay row", () => {
    const task: Task = {
      id: "abc",
      title: "Fix parser",
      status: "in_progress",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(formatTaskOverlayRow(task, 0)).toContain("Fix parser");
    expect(formatTaskOverlayRow(task, 0)).toContain("◐");
  });

  it("formats tasks overlay header", () => {
    const tasks: Task[] = [
      {
        id: "1",
        title: "a",
        status: "pending",
        createdAt: "",
        updatedAt: "",
      },
      {
        id: "2",
        title: "b",
        status: "completed",
        createdAt: "",
        updatedAt: "",
      },
    ];
    expect(formatTasksOverlayHeader(tasks)).toContain("2 task(s)");
    expect(formatTasksOverlayHeader([])).toBe("No tasks");
  });

  it("formats checkpoint overlay row and relative time", () => {
    const recent = new Date(Date.now() - 5 * 60_000).toISOString();
    expect(formatRelativeTime(recent)).toMatch(/min/);
    const row = formatCheckpointOverlayRow({
      name: "snap-1",
      metadata: {
        name: "snap-1",
        timestamp: recent,
        messageCount: 3,
        filesChanged: ["a.jac"],
        provider: { name: "openai", model: "gpt" },
      },
    });
    expect(row).toContain("snap-1");
    expect(row).toContain("3 msgs");
  });
});
