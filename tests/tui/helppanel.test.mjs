/**
 * Jackal HelpPanel — command reference (nanocoder embeds help in app shell)
 */
import { describe, expect, it } from "vitest";
import { renderInk, wrapPositional } from "../setup/render-helpers.mjs";
import { canRunTui, useTerminalWidth } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("HelpPanel (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadHelpPanel() {
    const mod = await import("../fixtures/tui/helppanel/module.mjs");
    return wrapPositional(mod.HelpPanel, [], {});
  }

  it("renders command reference header", async () => {
    const HelpPanel = await loadHelpPanel();
    const { frame, unmount } = renderInk(HelpPanel, {});
    expect(frame()).toMatch(/Commands/);
    unmount();
  });

  it("lists core slash commands", async () => {
    const HelpPanel = await loadHelpPanel();
    const { frame, unmount } = renderInk(HelpPanel, {});
    const out = frame();
    expect(out).toMatch(/\/help/);
    expect(out).toMatch(/\/login/);
    expect(out).toMatch(/\/logout/);
    expect(out).toMatch(/\/model/);
    expect(out).toMatch(/\/abort/);
    expect(out).toMatch(/\/clear/);
    expect(out).toMatch(/\/multiline/);
    expect(out).toMatch(/\/compact/);
    expect(out).toMatch(/\/exit/);
    unmount();
  });

  it("shows keyboard shortcut hints", async () => {
    const HelpPanel = await loadHelpPanel();
    const { frame, unmount } = renderInk(HelpPanel, {});
    const out = frame();
    expect(out).toMatch(/↑\/↓ = history/);
    expect(out).toMatch(/Tab = autocomplete/);
    expect(out).toMatch(/Esc = cancel/);
    expect(out).toMatch(/Ctrl\+C = exit/);
    unmount();
  });

  it("renders without crashing", async () => {
    const HelpPanel = await loadHelpPanel();
    const { frame, unmount } = renderInk(HelpPanel, {});
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });
});
