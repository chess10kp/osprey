import { describe, expect, it } from "vitest";
import { bridgeEvents, seedStoreFromSession } from "../../src/bridge.js";
import { AgentStore } from "../../src/store.js";

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

    unsub();
  });

  it("tracks tool execution lifecycle", () => {
    const store = new AgentStore();
    const session = createMockSession();
    const unsub = bridgeEvents(session, store);

    session.emit({
      type: "tool_execution_start",
      toolCallId: "t1",
      toolName: "read",
      input: { path: "foo.jac" },
    });
    expect(store.getSnapshot().toolExecutions.t1).toMatchObject({
      status: "running",
      toolName: "read",
    });

    session.emit({
      type: "tool_execution_end",
      toolCallId: "t1",
      toolName: "read",
      result: "ok",
    });
    expect(store.getSnapshot().toolExecutions.t1?.status).toBe("done");
    expect(store.getSnapshot().toolExecutions.t1?.result).toBe("ok");

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
  });
});
