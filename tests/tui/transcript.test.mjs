/**
 * Ported from nanocoder source/components/chat-queue.spec.tsx
 * and source/app/components/chat-history.spec.tsx
 */
import React from "react";
import { Text } from "ink";
import { describe, expect, it } from "vitest";
import { asPropsComponent, renderInk } from "../setup/render-helpers.mjs";
import { canRunTui, loadShellModule, useTerminalWidth } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("ChatQueue (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadChatQueue() {
    const mod = await loadShellModule();
    return asPropsComponent(mod.ChatQueue);
  }

  it("renders without messages", async () => {
    const ChatQueue = await loadChatQueue();
    const { frame, unmount } = renderInk(ChatQueue, { messages: [], model: "" });
    expect(typeof frame()).toBe("string");
    unmount();
  });

  it("renders with message rows", async () => {
    const ChatQueue = await loadChatQueue();
    const { frame, unmount } = renderInk(ChatQueue, {
      messages: [{ role: "user", text: "Static Content" }],
      model: "gpt-4",
    });
    expect(frame()).toMatch(/Static Content/);
    unmount();
  });

  it("renders multiple messages", async () => {
    const ChatQueue = await loadChatQueue();
    const { frame, unmount } = renderInk(ChatQueue, {
      messages: [
        { role: "user", text: "First message" },
        { role: "assistant", text: "Second message" },
      ],
      model: "gpt-4",
    });
    const out = frame();
    expect(out).toMatch(/First message/);
    expect(out).toMatch(/Second message/);
    unmount();
  });
});

describe.skipIf(!canRunTui)("ChatHistory (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadChatHistory() {
    const mod = await loadShellModule();
    return asPropsComponent(mod.ChatHistory);
  }

  it("renders without error", async () => {
    const ChatHistory = await loadChatHistory();
    const { frame, unmount } = renderInk(ChatHistory, {
      messages: [],
      model: "",
      live_component: null,
    });
    expect(typeof frame()).toBe("string");
    unmount();
  });

  it("renders static message components", async () => {
    const ChatHistory = await loadChatHistory();
    const { frame, unmount } = renderInk(ChatHistory, {
      messages: [{ role: "user", text: "Static Content" }],
      model: "gpt-4",
      live_component: null,
    });
    expect(frame()).toMatch(/Static Content/);
    unmount();
  });

  it("renders queued live component", async () => {
    const ChatHistory = await loadChatHistory();
    const { frame, unmount } = renderInk(ChatHistory, {
      transcript: [],
      model: "gpt-4",
      live_component: React.createElement(Text, {}, "Queued Content"),
    });
    expect(frame()).toMatch(/Queued Content/);
    unmount();
  });

  it("renders live tool component outside static queue", async () => {
    const ChatHistory = await loadChatHistory();
    const mod = await loadShellModule();
    const LiveToolRow = asPropsComponent(mod.LiveToolRow);
    const { frame, unmount } = renderInk(ChatHistory, {
      transcript: [
        { kind: "user", text: "run" },
        {
          kind: "tool",
          toolCallId: "t1",
          toolName: "bash",
          status: "running",
        },
      ],
      model: "",
      live_tool_component: React.createElement(LiveToolRow, {
        row: {
          kind: "tool",
          toolCallId: "t1",
          toolName: "bash",
          status: "running",
          input: { command: "ls" },
        },
        compact: false,
      }),
    });
    const out = frame();
    expect(out).toMatch(/run/);
    expect(out).toMatch(/bash/);
    expect(out).toMatch(/⏵/);
    unmount();
  });
});

describe.skipIf(!canRunTui)("TranscriptRow (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadTranscriptRow() {
    const mod = await loadShellModule();
    return asPropsComponent(mod.TranscriptRow);
  }

  it("routes user messages to UserMessage styling", async () => {
    const TranscriptRow = await loadTranscriptRow();
    const { frame, unmount } = renderInk(TranscriptRow, {
      msg: { role: "user", text: "Fix the bug" },
      model: "claude-3",
    });
    const out = frame();
    expect(out).toMatch(/You:/);
    expect(out).toMatch(/Fix the bug/);
    unmount();
  });

  it("routes assistant messages to AssistantMessage styling", async () => {
    const TranscriptRow = await loadTranscriptRow();
    const { frame, unmount } = renderInk(TranscriptRow, {
      msg: { role: "assistant", text: "On it." },
      model: "claude-3",
    });
    const out = frame();
    expect(out).toMatch(/claude-3:/);
    expect(out).toMatch(/On it/);
    unmount();
  });

  it("shows unknown roles with bracket prefix", async () => {
    const TranscriptRow = await loadTranscriptRow();
    const { frame, unmount } = renderInk(TranscriptRow, {
      msg: { kind: "system", text: "Boot complete" },
      model: "",
    });
    expect(frame()).toMatch(/\[system\]/);
    expect(frame()).toMatch(/Boot complete/);
    unmount();
  });

  it("routes tool entries to ToolMessage styling", async () => {
    const TranscriptRow = await loadTranscriptRow();
    const { frame, unmount } = renderInk(TranscriptRow, {
      msg: {
        kind: "tool",
        toolCallId: "t1",
        toolName: "read",
        status: "done",
        input: { path: "foo.jac" },
        result: "file contents",
        durationMs: 42,
      },
      model: "",
      compact: false,
    });
    const out = frame();
    expect(out).toMatch(/read/);
    expect(out).toMatch(/✓/);
    expect(out).toMatch(/file contents/);
    expect(out).toMatch(/42ms/);
    unmount();
  });

  it("shows running tool with play icon", async () => {
    const TranscriptRow = await loadTranscriptRow();
    const { frame, unmount } = renderInk(TranscriptRow, {
      msg: {
        kind: "tool",
        toolCallId: "t2",
        toolName: "bash",
        status: "running",
        input: { command: "ls" },
      },
      model: "",
    });
    const out = frame();
    expect(out).toMatch(/bash/);
    expect(out).toMatch(/⏵/);
    unmount();
  });
});

describe.skipIf(!canRunTui)("ChatQueue tool transcript", () => {
  useTerminalWidth(100);

  async function loadChatQueue() {
    const mod = await loadShellModule();
    return asPropsComponent(mod.ChatQueue);
  }

  it("renders frozen tool rows in transcript order", async () => {
    const ChatQueue = await loadChatQueue();
    const { frame, unmount } = renderInk(ChatQueue, {
      transcript: [
        { kind: "user", text: "read foo" },
        {
          kind: "tool",
          toolCallId: "t1",
          toolName: "read",
          status: "done",
          result: "ok",
        },
        { kind: "assistant", text: "Done" },
      ],
      model: "gpt-4",
    });
    const out = frame();
    expect(out).toMatch(/read foo/);
    expect(out).toMatch(/read/);
    expect(out).toMatch(/Done/);
    unmount();
  });

  it("omits running tools from static queue", async () => {
    const ChatQueue = await loadChatQueue();
    const { frame, unmount } = renderInk(ChatQueue, {
      transcript: [
        { kind: "user", text: "go" },
        {
          kind: "tool",
          toolCallId: "t1",
          toolName: "bash",
          status: "running",
        },
      ],
      model: "",
    });
    const out = frame();
    expect(out).toMatch(/go/);
    expect(out).not.toMatch(/bash/);
    unmount();
  });
});
