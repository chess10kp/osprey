/** @typedef {{ file: string, stem: string, exports: string[] }} ComponentSpec */

/** Single compile unit for all TUI render tests (see templates/tui-test.cl.jac). */
export const TUI_TEST = {
  file: "templates/tui-test.cl.jac",
  stem: "shell",
  exports: [
    "app",
    "WelcomeMessage",
    "StatusBar",
    "UserMessage",
    "AssistantMessage",
    "StreamingMessage",
    "ChatHistory",
    "ChatQueue",
    "TranscriptRow",
    "LiveToolRow",
    "ProviderPicker",
    "BrowserAuthView",
    "AuthPromptView",
    "ModelPicker",
    "AuthErrorView",
    "HelpPanel",
    "ToolRow",
    "ToolTimeline",
    "ToolMessage",
    "UserInput",
    "CompletionList",
  ],
};

/** @deprecated Use TUI_TEST — kept for compile-smoke iteration. */
export const COMPONENTS = [];
export const SHELL = TUI_TEST;
