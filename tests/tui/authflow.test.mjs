/**
 * Ported from nanocoder auth/modal selector overlay views
 */
import { describe, expect, it } from "vitest";
import { renderInk, wrapPositional } from "../setup/render-helpers.mjs";
import { canRunTui, loadShellModule, useTerminalWidth } from "../setup/tui-suite.mjs";
import { jacDict } from "../setup/jac-dict.mjs";

const providers = [
  jacDict({
    id: "anthropic",
    displayName: "Anthropic",
    authType: "api_key",
    modelCount: 3,
    configured: true,
  }),
  jacDict({
    id: "openrouter",
    displayName: "OpenRouter",
    authType: "api_key",
    modelCount: 10,
    configured: false,
  }),
];

describe.skipIf(!canRunTui)("AuthFlow views (nanocoder parity)", () => {
  useTerminalWidth(100);

  it("ProviderPicker lists providers with configured marker", async () => {
    const mod = await loadShellModule();
    const ProviderPicker = wrapPositional(mod.ProviderPicker, ["providers"], { providers: [] });
    const { frame, unmount } = renderInk(ProviderPicker, { providers });
    const out = frame();
    expect(out).toMatch(/Select a provider/);
    expect(out).toMatch(/anthropic/);
    expect(out).toMatch(/openrouter/);
    unmount();
  });

  it("BrowserAuthView shows URL and instructions", async () => {
    const mod = await loadShellModule();
    const BrowserAuthView = wrapPositional(mod.BrowserAuthView, ["url", "instructions"], {
      url: "",
      instructions: "",
    });
    const { frame, unmount } = renderInk(BrowserAuthView, {
      url: "https://example.com/oauth",
      instructions: "Complete login in browser",
    });
    const out = frame();
    expect(out).toMatch(/Browser authentication/);
    expect(out).toMatch(/https:\/\/example.com\/oauth/);
    expect(out).toMatch(/Complete login in browser/);
    unmount();
  });

  it("AuthPromptView shows message and input cursor", async () => {
    const mod = await loadShellModule();
    const AuthPromptView = wrapPositional(
      mod.AuthPromptView,
      ["message", "input_text", "placeholder"],
      { message: "", input_text: "", placeholder: "" },
    );
    const { frame, unmount } = renderInk(AuthPromptView, {
      message: "Enter API key",
      input_text: "sk-test",
      placeholder: "key",
    });
    const out = frame();
    expect(out).toMatch(/Enter API key/);
    expect(out).toMatch(/sk-test/);
    unmount();
  });

  it("ModelPicker shows filter hint and count", async () => {
    const mod = await loadShellModule();
    const ModelPicker = wrapPositional(mod.ModelPicker, ["models", "query"], {
      models: [],
      query: "",
    });
    const models = [
      jacDict({ provider: "anthropic", modelId: "claude-3-opus" }),
      jacDict({ provider: "openai", modelId: "gpt-4" }),
    ];
    const { frame, unmount } = renderInk(ModelPicker, { models, query: "" });
    const out = frame();
    expect(out).toMatch(/Select a model/);
    expect(out).toMatch(/2 models available/);
    unmount();
  });

  it("ModelPicker filters models by query", async () => {
    const mod = await loadShellModule();
    const ModelPicker = wrapPositional(mod.ModelPicker, ["models", "query"], {
      models: [],
      query: "",
    });
    const models = [
      jacDict({ provider: "anthropic", modelId: "claude-3-opus" }),
      jacDict({ provider: "openai", modelId: "gpt-4" }),
    ];
    const { frame, unmount } = renderInk(ModelPicker, { models, query: "openai" });
    expect(frame()).toMatch(/1 models available/);
    unmount();
  });

  it("AuthErrorView shows error message", async () => {
    const mod = await loadShellModule();
    const AuthErrorView = wrapPositional(mod.AuthErrorView, ["message"], { message: "" });
    const { frame, unmount } = renderInk(AuthErrorView, {
      message: "Invalid credentials",
    });
    const out = frame();
    expect(out).toMatch(/Auth error/);
    expect(out).toMatch(/Invalid credentials/);
    unmount();
  });
});
