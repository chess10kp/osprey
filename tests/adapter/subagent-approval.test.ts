import { describe, expect, it } from "vitest";
import { SubagentApprovalQueue } from "../../src/agent/subagent-approval.js";

describe("SubagentApprovalQueue", () => {
  it("resolves true when approved", async () => {
    const queue = new SubagentApprovalQueue();
    const promise = queue.requestApproval("id-1", "write", { path: "a.jac" }, "scout");
    expect(queue.pending?.subagentName).toBe("scout");
    expect(queue.pending?.toolName).toBe("write");
    expect(queue.approve()).toBe(true);
    await expect(promise).resolves.toBe(true);
    expect(queue.pending).toBeNull();
  });

  it("resolves false when rejected", async () => {
    const queue = new SubagentApprovalQueue();
    const promise = queue.requestApproval("id-2", "bash", { command: "ls" }, "implementer");
    expect(queue.reject()).toBe(true);
    await expect(promise).resolves.toBe(false);
  });

  it("notifies listener on pending changes", () => {
    const seen: Array<string | null> = [];
    const queue = new SubagentApprovalQueue((pending) => {
      seen.push(pending?.toolName ?? null);
    });
    void queue.requestApproval("id-3", "edit", {}, "architect");
    queue.approve();
    expect(seen).toEqual(["edit", null]);
  });

  it("cancel resolves pending request as rejected", async () => {
    const queue = new SubagentApprovalQueue();
    const promise = queue.requestApproval("id-4", "read", {}, "scout");
    queue.cancel();
    await expect(promise).resolves.toBe(false);
    expect(queue.pending).toBeNull();
  });

  it("returns false for second concurrent request", async () => {
    const queue = new SubagentApprovalQueue();
    const first = queue.requestApproval("id-5", "write", {}, "scout");
    const second = queue.requestApproval("id-6", "bash", {}, "scout");
    queue.approve();
    await expect(first).resolves.toBe(true);
    await expect(second).resolves.toBe(false);
  });
});
