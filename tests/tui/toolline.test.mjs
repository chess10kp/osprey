/**
 * Ported from nanocoder source/components/tool-message.spec.tsx
 * (Jackal ToolRow/ToolTimeline — no TitledBox/hideBox variants)
 */
import { describe, expect, it } from "vitest";
import { asPropsComponent, renderInk, wrapPositional } from "../setup/render-helpers.mjs";
import { canRunTui, useTerminalWidth } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("ToolRow (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadToolRow() {
    const mod = await import("../fixtures/tui/toolline/module.mjs");
    return asPropsComponent(mod.ToolRow);
  }

  it("renders without crashing", async () => {
    const ToolRow = await loadToolRow();
    const { frame, unmount } = renderInk(ToolRow, {
      tool_name: "Test Tool",
      status: "done",
      input_preview: "Test message",
    });
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("renders tool name", async () => {
    const ToolRow = await loadToolRow();
    const { frame, unmount } = renderInk(ToolRow, {
      tool_name: "Custom Title",
      status: "done",
      input_preview: "Test message",
    });
    expect(frame()).toMatch(/Custom Title/);
    unmount();
  });

  it("renders string detail preview", async () => {
    const ToolRow = await loadToolRow();
    const { frame, unmount } = renderInk(ToolRow, {
      tool_name: "read",
      status: "done",
      input_preview: "Hello world",
    });
    expect(frame()).toMatch(/Hello world/);
    unmount();
  });

  it("shows checkmark for completed tools", async () => {
    const ToolRow = await loadToolRow();
    const { frame, unmount } = renderInk(ToolRow, {
      tool_name: "read",
      status: "done",
      input_preview: "",
    });
    expect(frame()).toMatch(/✓/);
    unmount();
  });

  it("shows play icon for running tools", async () => {
    const ToolRow = await loadToolRow();
    const { frame, unmount } = renderInk(ToolRow, {
      tool_name: "bash",
      status: "running",
      input_preview: "",
    });
    expect(frame()).toMatch(/⏵/);
    unmount();
  });

  it("truncates long input preview to 60 chars", async () => {
    const ToolRow = await loadToolRow();
    const long = "a".repeat(61);
    const { frame, unmount } = renderInk(ToolRow, {
      tool_name: "edit",
      status: "done",
      input_preview: long,
    });
    const out = frame();
    expect(out).toMatch(/…/);
    expect(out).not.toMatch(long);
    unmount();
  });
});

describe.skipIf(!canRunTui)("ToolTimeline (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadToolTimeline() {
    const mod = await import("../fixtures/tui/toolline/module.mjs");
    return wrapPositional(mod.ToolTimeline, [
      "tool_name_list",
      "tool_status_list",
      "tool_input_list",
    ], {
      tool_name_list: [],
      tool_status_list: [],
      tool_input_list: [],
    });
  }

  it("renders Tools header", async () => {
    const ToolTimeline = await loadToolTimeline();
    const { frame, unmount } = renderInk(ToolTimeline, {
      tool_name_list: ["read"],
      tool_status_list: ["done"],
      tool_input_list: [""],
    });
    expect(frame()).toMatch(/Tools/);
    unmount();
  });

  it("shows only the last 8 tools", async () => {
    const ToolTimeline = await loadToolTimeline();
    const names = Array.from({ length: 10 }, (_, i) => `tool-${i}`);
    const { frame, unmount } = renderInk(ToolTimeline, {
      tool_name_list: names,
      tool_status_list: names.map(() => "done"),
      tool_input_list: names.map(() => ""),
    });
    const out = frame();
    expect(out).toMatch(/tool-9/);
    expect(out).not.toMatch(/tool-0/);
    expect(out).not.toMatch(/tool-1/);
    unmount();
  });
});
