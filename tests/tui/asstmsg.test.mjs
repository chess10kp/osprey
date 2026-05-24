/**
 * Ported from nanocoder source/components/assistant-message.spec.tsx
 * (markdown/HTML entity parser unit tests omitted — Jackal renders plain text)
 */
import { describe, expect, it } from "vitest";
import { asPropsComponent, renderInk } from "../setup/render-helpers.mjs";
import { canRunTui, loadShellModule, useTerminalWidth } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("AssistantMessage (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadAssistantMessage() {
    const mod = await loadShellModule();
    return asPropsComponent(mod.AssistantMessage);
  }

  it("renders with basic message", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "Hello world",
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/test-model:/);
    expect(out).toMatch(/Hello world/);
    unmount();
  });

  it("renders inline code markers as plain text", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "Use `const` for constants",
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/const/);
    expect(out).toMatch(/for constants/);
    unmount();
  });

  it("renders headings as plain text", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "# Main Heading",
      model: "test-model",
    });
    expect(frame()).toMatch(/Main Heading/);
    unmount();
  });

  it("renders list markers as plain text", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "- Item 1\n- Item 2\n- Item 3",
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/Item 1/);
    expect(out).toMatch(/Item 2/);
    expect(out).toMatch(/Item 3/);
    unmount();
  });

  it("renders without crashing with empty message", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "",
      model: "test-model",
    });
    expect(frame()).toMatch(/test-model:/);
    unmount();
  });

  it("renders model name correctly", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "Test",
      model: "gpt-4",
    });
    expect(frame()).toMatch(/gpt-4:/);
    unmount();
  });

  it("strips leading newlines from message body", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "\n\nHello world",
      model: "test-model",
    });
    expect(frame()).toMatch(/Hello world/);
    unmount();
  });

  it("strips trailing newlines from message body", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "Hello world\n\n",
      model: "test-model",
    });
    expect(frame()).toMatch(/Hello world/);
    unmount();
  });

  it("preserves internal newlines", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: "Line 1\nLine 2\nLine 3",
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/Line 1/);
    expect(out).toMatch(/Line 2/);
    expect(out).toMatch(/Line 3/);
    unmount();
  });

  it("renders markdown tables with border characters", async () => {
    const AssistantMessage = await loadAssistantMessage();
    const { frame, unmount } = renderInk(AssistantMessage, {
      message: `| Name | Value |
|------|-------|
| foo  | bar   |`,
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/Name/);
    expect(out).toMatch(/Value/);
    expect(out).toMatch(/foo/);
    expect(out).toMatch(/bar/);
    expect(out).toMatch(/[─│]/);
    unmount();
  });
});
