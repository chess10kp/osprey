import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import {
  AgentStore,
  MAX_TOOL_EXECUTIONS,
  STREAM_EMIT_MS,
} from "../../src/store.js";
import { MAX_TOOL_OUTPUT_BYTES } from "../../src/runtime/tool-output-limit.js";

describe("AgentStore memory bounds", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("throttles streaming emits", () => {
    const store = new AgentStore();
    const listener = vi.fn();
    store.subscribe(listener);

    store.beginStreaming();
    listener.mockClear();

    store.appendStreamText("a");
    store.appendStreamText("b");
    store.appendStreamText("c");

    expect(listener).not.toHaveBeenCalled();
    vi.advanceTimersByTime(STREAM_EMIT_MS);
    expect(listener).toHaveBeenCalledTimes(1);
    expect(store.getSnapshot().streamingText).toBe("abc");
  });

  it("flushes streaming emit on finalize", () => {
    const store = new AgentStore();
    const listener = vi.fn();
    store.subscribe(listener);

    store.beginStreaming();
    store.appendStreamText("hi");
    listener.mockClear();

    store.finalizeStreaming();
    expect(listener).toHaveBeenCalled();
    expect(store.getSnapshot().messages.at(-1)).toMatchObject({
      role: "assistant",
      text: "hi",
    });
  });

  it("truncates large tool results and caps toolExecutions", () => {
    const store = new AgentStore();
    const big = "x".repeat(MAX_TOOL_OUTPUT_BYTES + 500);

    for (let i = 0; i < MAX_TOOL_EXECUTIONS + 10; i++) {
      store.upsertToolExecution({
        toolCallId: `t${i}`,
        toolName: "read",
        status: "running",
      });
      store.upsertToolExecution({
        toolCallId: `t${i}`,
        toolName: "read",
        status: "done",
        result: big,
      });
    }

    const snap = store.getSnapshot();
    expect(Object.keys(snap.toolExecutions)).toHaveLength(MAX_TOOL_EXECUTIONS);
    expect(snap.toolExecutions.t49?.result).toContain("...[truncated at 50 KB]");
    expect(snap.toolExecutions.t0).toBeUndefined();
    expect(
      snap.transcript.filter((entry) => entry.kind === "tool"),
    ).toHaveLength(MAX_TOOL_EXECUTIONS);
  });

  it("pruneToolExecutions drops old transcript tool rows", () => {
    const store = new AgentStore();

    for (let i = 0; i < MAX_TOOL_EXECUTIONS + 5; i++) {
      store.upsertToolExecution({
        toolCallId: `p${i}`,
        toolName: "bash",
        status: "running",
      });
      store.upsertToolExecution({
        toolCallId: `p${i}`,
        toolName: "bash",
        status: "done",
        result: "ok",
      });
    }

    store.pruneToolExecutions(5);
    const snap = store.getSnapshot();
    expect(Object.keys(snap.toolExecutions)).toHaveLength(5);
    expect(snap.toolExecutions.p0).toBeUndefined();
    expect(snap.toolExecutions.p44).toBeDefined();
    expect(
      snap.transcript.filter((entry) => entry.kind === "tool"),
    ).toHaveLength(5);
  });
});
