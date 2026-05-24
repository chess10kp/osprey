import { beforeEach, describe, expect, it, vi } from "vitest";

const mockSession = vi.hoisted(() => {
  class MockJackalAgentSession {
    mode = "normal" as const;
    currentModel = { provider: "mock", id: "mock-model" };
    messages: unknown[] = [];
    private handlers = new Set<(event: { type?: string; [key: string]: unknown }) => void>();

    subscribe(handler: (event: { type?: string; [key: string]: unknown }) => void) {
      this.handlers.add(handler);
      return () => this.handlers.delete(handler);
    }

    private emit(event: { type?: string; [key: string]: unknown }) {
      for (const handler of this.handlers) handler(event);
    }

    async initialize() {
      this.emit({ type: "mcp_ready", server: "jac", toolCount: 1 });
    }

    scheduleMcpConnect() {}

    scheduleLspConnect() {}

    async shutdownBackground() {}

    async sendUserMessage(_text: string) {
      this.emit({ type: "agent_start" });
      this.emit({ type: "message_start", message: { role: "assistant" } });
      this.emit({
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", delta: "headless-ok" },
      });
      this.emit({ type: "message_end" });
      this.emit({ type: "agent_end" });
    }

    dispose() {}
  }

  return MockJackalAgentSession;
});

vi.mock("../../src/session/agent-session.js", () => ({
  JackalAgentSession: mockSession,
}));

import { runNextAgentSmoke } from "../../src/core/adapter.js";

describe("runNextAgentSmoke", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("boots mocked session and records bridge events", async () => {
    const result = await runNextAgentSmoke(process.cwd());

    expect(result.ok).toBe(true);
    expect(result.eventTypes).toContain("agent_start");
    expect(result.eventTypes).toContain("agent_end");
    expect(result.snapshotCount).toBeGreaterThan(0);
  });

  it("returns structured failure on thrown boot error", async () => {
    const originalInitialize = mockSession.prototype.initialize;
    mockSession.prototype.initialize = async function brokenInitialize() {
      throw new Error("boot failed");
    };

    try {
      const result = await runNextAgentSmoke(process.cwd());
      expect(result.ok).toBe(false);
      expect(result.error).toMatch(/boot failed/);
    } finally {
      mockSession.prototype.initialize = originalInitialize;
    }
  });
});
