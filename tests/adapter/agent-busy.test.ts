import { describe, expect, it } from "vitest";
import { isAgentBusy } from "../../src/core/agent-busy.js";
import type { AgentSnapshot } from "../../src/core/store.js";

function snap(overrides: Partial<AgentSnapshot>): AgentSnapshot {
  return {
    phase: "ready",
    sessionId: "",
    sessionName: "",
    model: null,
    provider: null,
    mode: "normal",
    messages: [],
    transcript: [],
    transcriptEpoch: 0,
    toolExecutions: {},
    streamingText: null,
    liveToolCallId: null,
    error: null,
    pendingApproval: null,
    pendingSubagentApproval: null,
    mcpStatus: "idle",
    mcpError: null,
    mcpToolCount: 0,
    ...overrides,
  };
}

describe("isAgentBusy", () => {
  it("is true while streaming", () => {
    expect(isAgentBusy(snap({ phase: "streaming" }))).toBe(true);
  });

  it("is true when a tool is running", () => {
    expect(
      isAgentBusy(
        snap({
          toolExecutions: {
            t1: {
              toolCallId: "t1",
              toolName: "read",
              status: "running",
            },
          },
        }),
      ),
    ).toBe(true);
  });

  it("is false when ready with no running tools", () => {
    expect(isAgentBusy(snap({}))).toBe(false);
  });
});
