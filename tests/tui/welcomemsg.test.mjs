/**
 * Ported from nanocoder source/components/welcome-message.spec.tsx
 */
import { describe, expect, it } from "vitest";
import { renderInk, wrapPositional } from "../setup/render-helpers.mjs";
import { canRunTui, loadShellModule, useTerminalWidth } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("WelcomeMessage (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadWelcome() {
    const mod = await loadShellModule();
    return wrapPositional(mod.WelcomeMessage, ["version"], { version: "" });
  }

  it("renders compact layout for narrow terminal", async () => {
    process.stdout.columns = 50;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("shows version in narrow layout", async () => {
    process.stdout.columns = 50;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: " v0.1" });
    expect(frame()).toMatch(/v0\.1/);
    unmount();
  });

  it("shows quick tips in narrow layout", async () => {
    process.stdout.columns = 50;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    const out = frame();
    expect(out).toMatch(/natural language/i);
    expect(out).toMatch(/\/help/);
    expect(out).toMatch(/Ctrl\+C/);
    unmount();
  });

  it("has bordered box in narrow layout", async () => {
    process.stdout.columns = 50;
    const WelcomeInk = await loadWelcome();
    const { rawFrame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(rawFrame()).toMatch(/[╭│╮─]/);
    unmount();
  });

  it("renders full layout for normal terminal", async () => {
    process.stdout.columns = 80;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame()).toMatch(/Jackal/);
    unmount();
  });

  it("shows welcome message for normal terminal", async () => {
    process.stdout.columns = 80;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: " v0.1" });
    expect(frame()).toMatch(/Welcome to Jackal v0\.1/);
    unmount();
  });

  it("shows concise tips for normal terminal", async () => {
    process.stdout.columns = 80;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    const out = frame();
    expect(out).toMatch(/1\. Use natural language to describe your task\./);
    expect(out).toMatch(/2\. Ask for file analysis, editing, bash commands and more\./);
    expect(out).toMatch(/3\. Be specific for best results\./);
    expect(out).toMatch(/4\. Type \/help for commands, \/exit or Ctrl\+C to quit\./);
    unmount();
  });

  it("shows help command for normal terminal", async () => {
    process.stdout.columns = 80;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame()).toMatch(/\/help for help/);
    unmount();
  });

  it("renders full layout for wide terminal", async () => {
    process.stdout.columns = 120;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame()).toMatch(/Jackal/);
    unmount();
  });

  it("renders without crashing", async () => {
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: " v0.1" });
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("has consistent layout structure", async () => {
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("displays ASCII banner art", async () => {
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame()).toMatch(/██/);
    unmount();
  });

  it("handles boundary at width 60", async () => {
    process.stdout.columns = 60;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame()).toMatch(/Jackal/);
    unmount();
  });

  it("handles boundary at width 100", async () => {
    process.stdout.columns = 100;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame()).toMatch(/Welcome to Jackal/);
    unmount();
  });

  it("handles very narrow terminal", async () => {
    process.stdout.columns = 30;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("handles very wide terminal", async () => {
    process.stdout.columns = 200;
    const WelcomeInk = await loadWelcome();
    const { frame, unmount } = renderInk(WelcomeInk, { version: "" });
    expect(frame()).toMatch(/Jackal/);
    unmount();
  });
});
