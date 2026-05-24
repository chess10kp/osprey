/** @typedef {{ file: string, stem: string, exports: string[] }} ComponentSpec */

/** @type {ComponentSpec[]} */
export const COMPONENTS = [
  {
    file: "templates/components/asstmsg.cl.jac",
    stem: "asstmsg",
    exports: ["AssistantMessage"],
  },
  {
    file: "templates/components/authflow.cl.jac",
    stem: "authflow",
    exports: [
      "ProviderPicker",
      "BrowserAuthView",
      "AuthPromptView",
      "ModelPicker",
      "AuthErrorView",
    ],
  },
  {
    file: "templates/components/helppanel.cl.jac",
    stem: "helppanel",
    exports: ["HelpPanel"],
  },
  {
    file: "templates/components/statusbar.cl.jac",
    stem: "statusbar",
    exports: ["StatusBar"],
  },
  {
    file: "templates/components/streammsg.cl.jac",
    stem: "streammsg",
    exports: ["StreamingMessage"],
  },
  {
    file: "templates/components/toolline.cl.jac",
    stem: "toolline",
    exports: ["ToolRow", "ToolTimeline"],
  },
  {
    file: "templates/components/transcript.cl.jac",
    stem: "transcript",
    exports: ["ChatHistory", "ChatQueue", "TranscriptRow"],
  },
  {
    file: "templates/components/userinput.cl.jac",
    stem: "userinput",
    exports: ["UserInput", "CompletionList"],
  },
  {
    file: "templates/components/usermsg.cl.jac",
    stem: "usermsg",
    exports: ["UserMessage"],
  },
  {
    file: "templates/components/welcomemsg.cl.jac",
    stem: "welcomemsg",
    exports: ["WelcomeMessage"],
  },
];

/** @type {ComponentSpec} */
export const SHELL = {
  file: "templates/shell.cl.jac",
  stem: "shell",
  exports: ["app", "StatusBar", "WelcomeMessage", "HelpPanel"],
};
