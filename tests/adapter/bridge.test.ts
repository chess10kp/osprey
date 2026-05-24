import { describe, expect, it } from "vitest";
import { bridgeEvents, seedStoreFromSession } from "../../src/core/bridge.js";
import { AgentStore } from "../../src/core/store.js";

type BridgeEvent = { type?: string; [key: string]: unknown };

function createMockSession() {
  const handlers = new Set<(event: BridgeEvent) => void>();
  return {
    handlers,
    subscribe(handler: (event: BridgeEvent) => void) {
      handlers.add(handler);
      return () => handlers.delete(handler);
    },
    emit(event: BridgeEvent) {
      for (const handler of handlers) handler(event);
    },
  };
}

describe("bridgeEvents", () => {
  it("sets phase to streaming on agent_start", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({ type: "agent_start" });
    expect(store.getSnapshot().phase).toBe("streaming");

    unsub();
  });

  it("returns to ready on agent_end and finalizes streaming text", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({ type: "agent_start" });
    session.emit({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "hi" } });
    session.emit({ type: "agent_end" });

    const snap = store.getSnapshot();
    expect(snap.phase).toBe("ready");
    expect(snap.streamingText).toBeNull();
    expect(snap.messages.at(-1)).toMatchObject({ role: "assistant", text: "hi" });
    expect(snap.transcript.at(-1)).toMatchObject({ kind: "assistant", text: "hi" });

    unsub();
  });

  it("tracks tool execution lifecycle in transcript order", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    store.pushUserMessage("read foo");
    session.emit({
      type: "tool_execution_start",
      toolCallId: "t1",
      toolName: "read",
      input: { path: "foo.jac" },
    });

    let snap = store.getSnapshot();
    expect(snap.toolExecutions.t1).toMatchObject({
      status: "running",
      toolName: "read",
    });
    expect(snap.liveToolCallId).toBe("t1");
    expect(snap.transcript).toEqual([
      { kind: "user", text: "read foo" },
      expect.objectContaining({
        kind: "tool",
        toolCallId: "t1",
        toolName: "read",
        status: "running",
        input: { path: "foo.jac" },
      }),
    ]);

    session.emit({
      type: "tool_execution_end",
      toolCallId: "t1",
      toolName: "read",
      result: "ok",
    });

    snap = store.getSnapshot();
    expect(snap.toolExecutions.t1?.status).toBe("done");
    expect(snap.toolExecutions.t1?.result).toBe("ok");
    expect(snap.liveToolCallId).toBeNull();
    expect(snap.transcript.at(-1)).toMatchObject({
      kind: "tool",
      toolCallId: "t1",
      status: "done",
      result: "ok",
      input: { path: "foo.jac" },
    });
    const toolEntry = snap.transcript.at(-1);
    expect(toolEntry?.kind === "tool" && toolEntry.durationMs).toBeTypeOf("number");

    unsub();
  });

  it("maps pi-agent args to input and preserves them on tool end", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({
      type: "tool_execution_start",
      toolCallId: "w1",
      toolName: "write",
      args: { path: "src/foo.jac", content: "walker init;" },
    });
    session.emit({
      type: "tool_execution_end",
      toolCallId: "w1",
      toolName: "write",
      result: "Wrote src/foo.jac",
    });

    expect(store.getSnapshot().toolExecutions.w1).toMatchObject({
      status: "done",
      input: { path: "src/foo.jac", content: "walker init;" },
      summary: "Wrote → src/foo.jac",
      result: "Wrote src/foo.jac",
    });

    unsub();
  });

  it("parses stringified JSON args and sets summary", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({
      type: "tool_execution_start",
      toolCallId: "r1",
      toolName: "read",
      args: '{"path":"templates/shell.cl.jac"}',
    });
    session.emit({
      type: "tool_execution_end",
      toolCallId: "r1",
      toolName: "read",
      result: "walker init;",
    });

    expect(store.getSnapshot().toolExecutions.r1).toMatchObject({
      status: "done",
      input: { path: "templates/shell.cl.jac" },
      summary: "Read @ templates/shell.cl.jac",
    });

    unsub();
  });

  it("finalizes streaming assistant text before tool start", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "Checking" } });
    session.emit({
      type: "tool_execution_start",
      toolCallId: "t1",
      toolName: "read",
      input: {},
    });

    const snap = store.getSnapshot();
    expect(snap.streamingText).toBeNull();
    expect(snap.transcript).toEqual([
      { kind: "assistant", text: "Checking" },
      expect.objectContaining({ kind: "tool", toolCallId: "t1", status: "running" }),
    ]);

    unsub();
  });

  it("marks failed tool executions as error in transcript", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({
      type: "tool_execution_start",
      toolCallId: "t1",
      toolName: "bash",
      input: { command: "false" },
    });
    session.emit({
      type: "tool_execution_end",
      toolCallId: "t1",
      toolName: "bash",
      result: { error: "exit 1" },
    });

    expect(store.getSnapshot().transcript.at(-1)).toMatchObject({
      kind: "tool",
      status: "error",
      result: "exit 1",
    });

    unsub();
  });

  it("extracts text content from pi-agent tool results for display", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({
      type: "tool_execution_start",
      toolCallId: "t2",
      toolName: "read",
      input: { path: "foo.jac" },
    });
    session.emit({
      type: "tool_execution_end",
      toolCallId: "t2",
      toolName: "read",
      result: {
        content: [{ type: "text", text: "walker foo;\n" }],
        details: { path: "foo.jac", bytes: 12 },
      },
    });

    expect(store.getSnapshot().toolExecutions.t2?.result).toBe("walker foo;\n");

    unsub();
  });

  it("updates model on model_select", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({ type: "model_select", provider: "anthropic", model: "claude-3" });
    expect(store.getSnapshot()).toMatchObject({
      provider: "anthropic",
      model: "claude-3",
    });

    unsub();
  });

  it("clears transcript on new session_start", () => {
    const store = new AgentStore();
    store.pushUserMessage("old");
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({ type: "session_start", sessionId: "s2", reason: "new" });
    expect(store.getSnapshot().messages).toEqual([]);
    expect(store.getSnapshot().transcript).toEqual([]);

    unsub();
  });

  it("sets MCP status on mcp_ready", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({ type: "mcp_ready", server: "jac", toolCount: 19 });
    expect(store.getSnapshot()).toMatchObject({
      mcpConnected: true,
      mcpConnecting: false,
      mcpServer: "jac",
      mcpToolCount: 19,
    });

    unsub();
  });

  it("changes dev mode on mode_change", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({ type: "mode_change", mode: "yolo" });
    expect(store.getSnapshot().mode).toBe("yolo");

    unsub();
  });
});

describe("seedStoreFromSession", () => {
  it("seeds model, session, and transcript", () => {
    const store = new AgentStore();
    seedStoreFromSession(store, {
      mode: "normal",
      provider: "anthropic",
      model: "claude-3",
      sessionId: "abc",
      sessionName: "demo",
      messages: [{ role: "user", content: "hello" }],
    });

    const snap = store.getSnapshot();
    expect(snap.provider).toBe("anthropic");
    expect(snap.model).toBe("claude-3");
    expect(snap.sessionId).toBe("abc");
    expect(snap.messages).toEqual([{ role: "user", text: "hello" }]);
    expect(snap.transcript).toEqual([{ kind: "user", text: "hello" }]);
  });
});
