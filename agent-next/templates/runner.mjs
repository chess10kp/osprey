import React from "react";
import { render, Text } from "ink";
import * as ShellModule from "./module.mjs";

const showError = (msg) => {
  render(React.createElement(Text, { color: "red" }, msg));
  process.exitCode = 1;
};

function boot() {
  const App = ShellModule.app;
  if (!App) {
    showError("shell.cl.jac did not export 'app'");
    return;
  }

  render(React.createElement(App));
}

try {
  boot();
} catch (err) {
  showError(`Jackal failed: ${err?.message || err}`);
}
