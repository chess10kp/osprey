#!/usr/bin/env node
/**
 * Capture the Ink render instance so the Jackal facade can force a redraw
 * after /clear (adapter must not write ANSI clears directly to stdout).
 */
import { readFileSync, writeFileSync } from "node:fs";

const runnerPath = process.argv[2];
if (!runnerPath) {
  console.error("patch-tui-runner: missing runner.mjs path");
  process.exit(1);
}

let src = readFileSync(runnerPath, "utf8");

if (src.includes("__JACKAL_INK")) {
  // Already patched with the Ink capture helper. But still ensure exitOnCtrlC fix.
  src = src.replace(
    /__jackalCaptureInk\(node,\s*render\(node\)\)/g,
    '__jackalCaptureInk(node, render(node, { exitOnCtrlC: false }))',
  );
  src = src.replace(
    /__jackalCaptureInk\(value,\s*render\(value\)\)/g,
    '__jackalCaptureInk(value, render(value, { exitOnCtrlC: false }))',
  );
  // Also fix cases already patched with exitOnCtrlC (idempotent)
  writeFileSync(runnerPath, src);
  process.exit(0);
}

const importsEnd = src.indexOf("const entryName");
if (importsEnd === -1) {
  console.error("patch-tui-runner: runner.mjs layout unexpected");
  process.exit(1);
}

const helper = `
const __jackalCaptureInk = (root, instance) => {
  globalThis.__JACKAL_INK = instance;
  globalThis.__JACKAL_INK_ROOT = root;
  return instance;
};

`;

src = src.slice(0, importsEnd) + helper + src.slice(importsEnd);

src = src.replace(
  `const showError = (msg) => {
  render(React.createElement(Text, {color: "red"}, msg));
  process.exitCode = 1;
};`,
  `const showError = (msg) => {
  const node = React.createElement(Text, {color: "red"}, msg);
  __jackalCaptureInk(node, render(node));
  process.exitCode = 1;
};`,
);

src = src.replace(
  `const mount = (value) => {
  if (React.isValidElement(value)) {
    render(value);
    return;
  }
  render(React.createElement(Text, {}, String(value)));
};`,
  `const mount = (value) => {
  if (React.isValidElement(value)) {
    __jackalCaptureInk(value, render(value));
    return;
  }
  const node = React.createElement(Text, {}, String(value));
  __jackalCaptureInk(node, render(node));
};`,
);

src = src.replace(
  `    if (typeof chosen === "function") {
      render(React.createElement(chosen));
    } else {
      mount(chosen);
    }`,
  `    if (typeof chosen === "function") {
      const node = React.createElement(chosen);
      __jackalCaptureInk(node, render(node));
    } else {
      mount(chosen);
    }`,
);

// ── Disable Ink's exitOnCtrlC: Jackal owns Ctrl+C handling via the facade ──
// Replace `render(node)` calls with `render(node, { exitOnCtrlC: false })` so
// Ink doesn't fight with our SIGINT handler.

// Replace the direct render() calls inside __jackalCaptureInk that were just added.
src = src.replace(
  /__jackalCaptureInk\(node,\s*render\(node\)\)/g,
  '__jackalCaptureInk(node, render(node, { exitOnCtrlC: false }))',
);
src = src.replace(
  /__jackalCaptureInk\(value,\s*render\(value\)\)/g,
  '__jackalCaptureInk(value, render(value, { exitOnCtrlC: false }))',
);

writeFileSync(runnerPath, src);
