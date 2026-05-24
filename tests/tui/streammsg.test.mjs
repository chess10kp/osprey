/**
 * Ported from nanocoder source/components/streaming-message.spec.tsx
 */
import { describe, expect, it } from "vitest";
import { asPropsComponent, renderInk } from "../setup/render-helpers.mjs";
import { canRunTui, loadShellModule, useTerminalWidth } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("StreamingMessage (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadStreamingMessage() {
    const mod = await loadShellModule();
    return asPropsComponent(mod.StreamingMessage);
  }

  it("renders with message and model", async () => {
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: "Hello world",
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/test-model/);
    expect(out).toMatch(/Hello world/);
    expect(out).toMatch(/~\d+ tokens/);
    unmount();
  });

  it("renders markdown-like text without formatting", async () => {
    const message = `# Title

This has **bold** and *italic* text.

- List item

Price: &euro;50`;
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: message,
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/# Title/);
    expect(out).toMatch(/\*\*bold\*\*/);
    expect(out).toMatch(/\*italic\*/);
    expect(out).toMatch(/&euro;50/);
    unmount();
  });

  it("truncates long messages to last 15 lines", async () => {
    const message = [...Array(16).keys()].map((s) => `line ${s}`).join("\n");
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: message,
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/test-model/);
    expect(out).toMatch(/…/);
    expect(out).toMatch(/line 14/);
    expect(out).not.toMatch(/line 0/);
    unmount();
  });

  it("renders without crashing with empty message", async () => {
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: "",
      model: "test-model",
    });
    expect(frame()).toMatch(/test-model/);
    unmount();
  });

  it("uses Thinking label when model is empty", async () => {
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: "Working",
      model: "",
    });
    expect(frame()).toMatch(/Thinking/);
    unmount();
  });

  it("strips leading newlines from display", async () => {
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: "\n\nHello world",
      model: "test-model",
    });
    expect(frame()).toMatch(/Hello world/);
    unmount();
  });

  it("strips trailing newlines from display", async () => {
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: "Hello world\n\n",
      model: "test-model",
    });
    expect(frame()).toMatch(/Hello world/);
    unmount();
  });

  it("preserves internal newlines", async () => {
    const StreamingMessage = await loadStreamingMessage();
    const { frame, unmount } = renderInk(StreamingMessage, {
      streaming_text: "Line 1\nLine 2\nLine 3",
      model: "test-model",
    });
    const out = frame();
    expect(out).toMatch(/Line 1/);
    expect(out).toMatch(/Line 2/);
    expect(out).toMatch(/Line 3/);
    unmount();
  });
});
