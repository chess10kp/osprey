import { createNextAgent } from "../dist/index.js";
import { TUI, ProcessTerminal } from "@earendil-works/pi-tui";
import chalk from "chalk";

const state = {
  phase: "booting",
  modelLabel: "no model",
  status: "booting",
  input: "",
  messages: [],
  streamingText: null,
  error: null,
};

let agent = null;
let tui = null;

function renderLines(width) {
  const lines = [];
  lines.push(`🐺 Jackal    ${chalk.cyan(state.phase)}    ${chalk.dim(state.modelLabel)}`);
  lines.push(chalk.gray("─".repeat(width)));

  const shown = state.messages.slice(-60);
  if (shown.length === 0 && !state.streamingText) {
    lines.push(chalk.dim("No messages yet. Type a prompt and press Enter."));
  } else {
    for (const msg of shown) {
      const prefix = msg.role === "user" ? chalk.cyan("> ") : "";
      for (const line of (msg.text || "").split("\n")) lines.push(prefix + line);
      lines.push("");
    }
    if (state.streamingText) {
      for (const line of state.streamingText.split("\n")) lines.push(chalk.green(line));
    }
  }

  const statusParts = [state.status, "/abort", "/clear", "/exit"];
  if (state.error) statusParts.unshift(`error: ${state.error}`);
  lines.push(chalk.dim(`┌${"─".repeat(width - 2)}┐`));
  lines.push(chalk.dim(`│ ${statusParts.join("  |  ")} │`));
  lines.push(chalk.green("❯ ") + state.input + chalk.dim("█"));
  return lines;
}

class ShellApp {
  render(width) {
    return renderLines(width);
  }

  handleInput(data) {
    if (data === "\r") {
      submit();
      return;
    }
    if (data === "\x7f" || data === "\b") {
      state.input = state.input.slice(0, -1);
      tui.requestRender();
      return;
    }
    if (data.length === 1 && data.charCodeAt(0) >= 32) {
      state.input += data;
      tui.requestRender();
    }
  }

  invalidate() {}
}

function syncFromStore() {
  if (!agent) return;
  const snap = agent.store.getSnapshot();
  state.phase = snap.phase;
  state.streamingText = snap.streamingText;
  state.error = snap.error;
  state.messages = snap.messages;
  state.modelLabel = snap.model ? `${snap.provider}/${snap.model}` : "no model configured";
  state.status = snap.phase === "streaming" ? "responding" : "ready";
  tui?.requestRender();
}

function submit() {
  const cmd = state.input.trim();
  state.input = "";
  if (!cmd) {
    tui.requestRender();
    return;
  }

  if (cmd === "/exit" || cmd === "/quit") {
    cleanup();
    return;
  }

  if (cmd === "/clear") {
    state.messages = [];
    state.streamingText = null;
    state.status = "cleared";
    tui.requestRender();
    return;
  }

  if (cmd === "/abort") {
    state.status = "aborting";
    tui.requestRender();
    agent.actions.abort().then(() => {
      state.status = "aborted";
      tui.requestRender();
    }).catch((err) => {
      state.error = err?.message || String(err);
      state.status = "error";
      tui.requestRender();
    });
    return;
  }

  state.status = "responding";
  tui.requestRender();
  agent.actions.send(cmd).catch((err) => {
    state.error = err?.message || String(err);
    state.status = "error";
    tui.requestRender();
  });
}

async function main() {
  const terminal = new ProcessTerminal();
  tui = new TUI(terminal);
  const app = new ShellApp();
  tui.addChild(app);
  tui.setFocus(app);

  try {
    agent = await createNextAgent(process.cwd());
    agent.store.subscribe(syncFromStore);
    syncFromStore();
    state.phase = "ready";
    state.status = state.modelLabel === "no model configured" ? "ready (login/model needed)" : "ready";
  } catch (err) {
    state.phase = "error";
    state.error = err?.message || String(err);
    state.status = "failed";
  }

  tui.start();
}

let _cleaned = false;
function cleanup() {
  if (_cleaned) return;
  _cleaned = true;
  try { agent?.actions.dispose(); } catch {}
  try { tui?.stop(); } catch {}
  process.exit(0);
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);

main().catch((err) => {
  console.error("Jackal failed to start:", err);
  process.exit(1);
});
