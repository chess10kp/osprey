/**
 * Ported from nanocoder source/components/status.spec.tsx
 * (Jackal StatusBar subset — no LSP, AGENTS.md, update banner, or narrow layout fork)
 */
import { describe, expect, it } from "vitest";
import { renderInk, wrapPositional } from "../setup/render-helpers.mjs";
import { canRunTui, loadShellModule, useTerminalWidth } from "../setup/tui-suite.mjs";

const defaultProps = {
  phase: "ready",
  model: "anthropic/claude-3-opus",
  provider: "openrouter",
  context_percent: 25,
  mcp_connected: 0,
  mcp_total: 0,
};

describe.skipIf(!canRunTui)("StatusBar (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadStatusBar() {
    const mod = await loadShellModule();
    return wrapPositional(mod.StatusBar, [
      "phase",
      "model",
      "provider",
      "context_percent",
      "mcp_connected",
      "mcp_total",
    ], {
      phase: "ready",
      model: "",
      provider: "",
      context_percent: 0,
      mcp_connected: 0,
      mcp_total: 0,
    });
  }

  it("renders layout without crashing", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, defaultProps);
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("shows model in layout", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, {
      ...defaultProps,
      model: "test-model",
    });
    expect(frame()).toMatch(/test-model/);
    unmount();
  });

  it("shows provider in layout", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, {
      ...defaultProps,
      provider: "test-provider",
    });
    expect(frame()).toMatch(/test-provider/);
    unmount();
  });

  it("shows ready phase label", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, { ...defaultProps, phase: "ready" });
    expect(frame()).toMatch(/Ready/);
    unmount();
  });

  it("shows streaming phase as Thinking", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, { ...defaultProps, phase: "streaming" });
    expect(frame()).toMatch(/Thinking/);
    unmount();
  });

  it("shows error phase label", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, { ...defaultProps, phase: "error" });
    expect(frame()).toMatch(/Error/);
    unmount();
  });

  it("shows booting phase label", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, { ...defaultProps, phase: "booting" });
    expect(frame()).toMatch(/Booting/);
    unmount();
  });

  it("shows compacting phase label", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, { ...defaultProps, phase: "compacting" });
    expect(frame()).toMatch(/Compacting/);
    unmount();
  });

  it("shows placeholder when model is empty", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, { ...defaultProps, model: "" });
    expect(frame()).toMatch(/\(no model\)/);
    unmount();
  });

  it("shows MCP status when servers configured", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, {
      ...defaultProps,
      mcp_connected: 2,
      mcp_total: 2,
    });
    expect(frame()).toMatch(/MCP: 2\/2/);
    unmount();
  });

  it("shows partial MCP connection", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, {
      ...defaultProps,
      mcp_connected: 1,
      mcp_total: 2,
    });
    expect(frame()).toMatch(/MCP: 1\/2/);
    unmount();
  });

  it("hides MCP line when mcp_total is 0", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, defaultProps);
    expect(frame()).not.toMatch(/MCP:/);
    unmount();
  });

  it("warns to compact when context is high", async () => {
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, {
      ...defaultProps,
      context_percent: 65,
    });
    const out = frame();
    expect(out).toMatch(/Context: 65%/);
    expect(out).toMatch(/\(use \/compact\)/);
    unmount();
  });

  it("handles very long model names", async () => {
    const longModel = "anthropic/claude-3-opus-very-long-model-name-that-might-truncate";
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, {
      ...defaultProps,
      model: longModel,
    });
    expect(frame()).toMatch(/claude-3-opus-very-long-model-name/);
    unmount();
  });

  it("renders in narrow terminal width", async () => {
    process.stdout.columns = 50;
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, defaultProps);
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("renders in wide terminal width", async () => {
    process.stdout.columns = 120;
    const StatusBarInk = await loadStatusBar();
    const { frame, unmount } = renderInk(StatusBarInk, defaultProps);
    expect(frame()).toMatch(/Jackal/);
    unmount();
  });
});
