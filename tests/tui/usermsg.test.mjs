/**
 * Ported from nanocoder source/components/user-message.spec.tsx
 * (file-placeholder and VS Code context cases omitted — not in Jackal yet)
 */
import { describe, expect, it } from "vitest";
import { asPropsComponent, renderInk } from "../setup/render-helpers.mjs";
import { canRunTui, loadShellModule, useTerminalWidth } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("UserMessage (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadUserMessage() {
    const mod = await loadShellModule();
    return asPropsComponent(mod.UserMessage);
  }

  it("renders with basic message", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, { message: "Hello world", tokens: 0 });
    const out = frame();
    expect(out).toMatch(/You:/);
    expect(out).toMatch(/Hello world/);
    unmount();
  });

  it("renders without file placeholders unchanged", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, {
      message: "This is a normal message",
      tokens: 0,
    });
    expect(frame()).toMatch(/This is a normal message/);
    unmount();
  });

  it("renders multi-line message", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, {
      message: "Line 1\nLine 2\nLine 3",
      tokens: 0,
    });
    const out = frame();
    expect(out).toMatch(/Line 1/);
    expect(out).toMatch(/Line 2/);
    expect(out).toMatch(/Line 3/);
    unmount();
  });

  it("renders with empty message", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, { message: "", tokens: 0 });
    expect(frame()).toMatch(/You:/);
    unmount();
  });

  it("does not treat email @ as special placeholder syntax", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, {
      message: "Email me at user@example.com",
      tokens: 0,
    });
    expect(frame()).toMatch(/user@example\.com/);
    unmount();
  });

  it("renders paragraphs with spacing", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, {
      message: "First paragraph\n\nSecond paragraph\n\nThird paragraph",
      tokens: 0,
    });
    const out = frame();
    expect(out).toMatch(/First paragraph/);
    expect(out).toMatch(/Second paragraph/);
    expect(out).toMatch(/Third paragraph/);
    unmount();
  });

  it("renders without crashing", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, { message: "Test", tokens: 0 });
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("displays approximate token count when tokens provided", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, { message: "Hello world", tokens: 3 });
    expect(frame()).toMatch(/~3 tokens/);
    unmount();
  });

  it("hides token footer when tokens is zero", async () => {
    const UserMessage = await loadUserMessage();
    const { frame, unmount } = renderInk(UserMessage, { message: "Hello", tokens: 0 });
    expect(frame()).not.toMatch(/tokens/);
    unmount();
  });
});
