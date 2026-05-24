/**
 * Ported from nanocoder source/components/user-input.spec.tsx
 * and source/app/components/chat-input.spec.tsx (UserInput subset)
 */
import { describe, expect, it } from "vitest";
import { renderInk, wrapPositional } from "../setup/render-helpers.mjs";
import { canRunTui, useTerminalWidth, defaultUserInputProps } from "../setup/tui-suite.mjs";

describe.skipIf(!canRunTui)("CompletionList (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadCompletionList() {
    const mod = await import("../fixtures/tui/userinput/module.mjs");
    return wrapPositional(mod.CompletionList, ["items", "selected_index"], {
      items: [],
      selected_index: 0,
    });
  }

  it("renders available commands header", async () => {
    const CompletionList = await loadCompletionList();
    const { frame, unmount } = renderInk(CompletionList, {
      items: ["/help", "/exit"],
      selected_index: 0,
    });
    expect(frame()).toMatch(/Available commands/);
    unmount();
  });

  it("highlights selected completion with arrow marker", async () => {
    const CompletionList = await loadCompletionList();
    const { frame, unmount } = renderInk(CompletionList, {
      items: ["/help", "/model"],
      selected_index: 1,
    });
    const out = frame();
    expect(out).toMatch(/\/help/);
    expect(out).toMatch(/\/model/);
    expect(out).toMatch(/▸/);
    unmount();
  });

  it("shows at most 8 completion items", async () => {
    const CompletionList = await loadCompletionList();
    const items = Array.from({ length: 12 }, (_, i) => `/cmd-${i}`);
    const { frame, unmount } = renderInk(CompletionList, { items, selected_index: 0 });
    const out = frame();
    expect(out).toMatch(/\/cmd-0/);
    expect(out).not.toMatch(/\/cmd-11/);
    unmount();
  });
});

describe.skipIf(!canRunTui)("UserInput (nanocoder parity)", () => {
  useTerminalWidth(100);

  async function loadUserInput() {
    const mod = await import("../fixtures/tui/userinput/module.mjs");
    return wrapPositional(
      mod.UserInput,
      ["input_text", "placeholder", "completions", "completion_index", "disabled", "on_change", "on_submit"],
      defaultUserInputProps,
    );
  }

  it("renders without error", async () => {
    const UserInput = await loadUserInput();
    const { frame, unmount } = renderInk(UserInput, defaultUserInputProps);
    expect(frame().length).toBeGreaterThan(0);
    unmount();
  });

  it("shows default prompt text", async () => {
    const UserInput = await loadUserInput();
    const { frame, unmount } = renderInk(UserInput, defaultUserInputProps);
    expect(frame()).toMatch(/What would you like me to help with/);
    unmount();
  });

  it("shows bash mode prompt for ! commands", async () => {
    const UserInput = await loadUserInput();
    const { frame, unmount } = renderInk(UserInput, {
      ...defaultUserInputProps,
      input_text: "!ls",
    });
    expect(frame()).toMatch(/Bash mode/);
    unmount();
  });

  it("shows cancel hint when disabled", async () => {
    const UserInput = await loadUserInput();
    const { frame, unmount } = renderInk(UserInput, {
      ...defaultUserInputProps,
      disabled: true,
    });
    expect(frame()).toMatch(/Press Esc to cancel/);
    unmount();
  });

  it("renders with completions prop without crashing", async () => {
    const UserInput = await loadUserInput();
    const { frame, unmount } = renderInk(UserInput, {
      ...defaultUserInputProps,
      completions: ["/help", "/exit"],
      completion_index: 0,
    });
    expect(typeof frame()).toBe("string");
    unmount();
  });
});
