import React from "react";
import { render, Text } from "ink";
import { createNextAgent } from "../dist/index.js";
import { AuthStorage, ModelRegistry } from "@earendil-works/pi-coding-agent";
import * as ShellModule from "./module.mjs";

const showError = (msg) => {
  render(React.createElement(Text, { color: "red" }, msg));
  process.exitCode = 1;
};

async function boot() {
  const cwd = process.cwd();

  // Boot adapter with real auth
  const authStorage = AuthStorage.create();
  const modelRegistry = ModelRegistry.create(authStorage);

  let agent;
  try {
    agent = await createNextAgent(cwd, { authStorage, modelRegistry });
  } catch (err) {
    showError(`Jackal boot failed: ${err?.message || err}`);
    return;
  }

  // Inject adapter into global scope for the .cl.jac app
  globalThis.__jackal = {
    store: agent.store,
    actions: {
      ...agent.actions,
      abort: () => {
        try { agent.actions.dispose(); } catch {}
      },
    },
    authActions: agent.authActions,
    authFlow: agent.authFlow,
  };

  // Mount the Ink app
  const App = ShellModule.app;
  if (!App) {
    showError("shell.cl.jac did not export 'app'");
    return;
  }

  render(React.createElement(App));

  process.on("SIGINT", () => {
    agent.actions.dispose();
    process.exit(0);
  });
  process.on("SIGTERM", () => {
    agent.actions.dispose();
    process.exit(0);
  });
}

boot().catch((err) => {
  showError(`Jackal failed: ${err?.message || err}`);
});
