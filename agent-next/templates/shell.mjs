// ────────────────────────────────────────────────────────────────────────────
// Jackal Shell — the actual working TUI.
//
// Boots a Pi AgentSession via our compiled adapter, renders messages,
// streaming text, tool calls, and accepts keyboard input using pi-tui.
//
// Run: node shell.mjs
// ────────────────────────────────────────────────────────────────────────────

import { createNextAgent } from "../dist/index.js";
import { TUI, Box, Text, Input, Markdown } from "@earendil-works/pi-tui";
import { ProcessTerminal } from "@earendil-works/pi-tui";
import chalk from "chalk";

// ──── Shell state ──────────────────────────────────────────────────────────

const state = {
  store: null,
  actions: null,
  input: "",
  phase: "booting",
  model: "",
  provider: "",
  messages: [],
  streamingText: null,
  toolExecutions: {},
  error: null,
  overlay: null, // null | "help" | "tools"
};

// ──── Rendering helpers ────────────────────────────────────────────────────

function phaseColor(phase) {
  switch (phase) {
    case "streaming": return "green";
    case "error": return "red";
    case "compacting": return "yellow";
    case "retrying": return "magenta";
    default: return "cyan";
  }
}

function truncate(s, max = 120) {
  if (!s) return "";
  const flat = s.replace(/\n/g, "↵");
  return flat.length > max ? flat.slice(0, max) + "…" : flat;
}

// ──── Components ────────────────────────────────────────────────────────────

function renderHeader(width) {
  const phase = state.phase;
  const color = phaseColor(phase);
  const model = state.model ? `${state.provider}/${state.model}` : "no model";
  const header = `🐺 Jackal    ${chalk[color](phase)}    ${chalk.dim(model)}`;
  const sep = chalk.gray("─".repeat(width));
  return [header, sep];
}

function renderMessages(width) {
  const lines = [];
  const msgs = state.messages.slice(-100);

  for (const msg of msgs) {
    const prefix = msg.role === "user" ? "> " : "";
    if (msg.role === "user") {
      for (const line of msg.text.split("\n")) {
        lines.push(chalk.cyan(prefix + line));
      }
    } else {
      for (const line of msg.text.split("\n")) {
        lines.push(line);
      }
    }
    lines.push("");
  }

  // Tool summary
  const tools = Object.values(state.toolExecutions);
  if (tools.length > 0) {
    lines.push(chalk.dim(`── tools (${tools.length}) ──`));
    for (const t of tools.slice(-6)) {
      const icon = t.status === "running" ? "⏳" : "✓";
      const c = t.status === "running" ? chalk.yellow : chalk.green;
      lines.push(c(`  ${icon} ${t.toolName}`));
    }
    lines.push(chalk.dim("──────────────"));
  }

  // Streaming text
  if (state.streamingText) {
    for (const line of state.streamingText.split("\n")) {
      lines.push(chalk.green(line));
    }
  }

  if (lines.length === 0) {
    lines.push(chalk.dim("No messages yet. Type a prompt and press Enter."));
  }

  return lines;
}

function renderHelpOverlay(width) {
  const border = "─".repeat(width - 2);
  return [
    chalk.yellow(`┌${border}┐`),
    chalk.yellow("│ ") + chalk.bold("Commands:") + " ".repeat(width - 13) + chalk.yellow("│"),
    chalk.yellow("│ ") + "  /help        Show this help" + " ".repeat(width - 32) + chalk.yellow("│"),
    chalk.yellow("│ ") + "  /model       Show current model" + " ".repeat(width - 37) + chalk.yellow("│"),
    chalk.yellow("│ ") + "  /clear       Clear messages" + " ".repeat(width - 32) + chalk.yellow("│"),
    chalk.yellow("│ ") + "  /tools       Show tool execution log" + " ".repeat(width - 41) + chalk.yellow("│"),
    chalk.yellow("│ ") + "  /exit, /quit Exit Jackal" + " ".repeat(width - 31) + chalk.yellow("│"),
    chalk.yellow("│ ") + "  Esc          Abort streaming" + " ".repeat(width - 35) + chalk.yellow("│"),
    chalk.yellow(`└${border}┘`),
    chalk.dim("Press any key to dismiss"),
  ];
}

function renderToolsOverlay(width) {
  const tools = Object.values(state.toolExecutions);
  if (tools.length === 0) {
    return [chalk.dim("No tool executions recorded."), "", chalk.dim("Press any key to dismiss")];
  }
  const lines = [];
  for (const t of tools) {
    const icon = t.status === "running" ? "⏳" : "✓";
    const c = t.status === "running" ? chalk.yellow : chalk.green;
    lines.push(c(`${icon} ${t.toolName}`));
    const result = t.result ? truncate(t.result, 200) : "(no result)";
    lines.push(chalk.dim(`   ${result}`));
  }
  lines.push("");
  lines.push(chalk.dim("Press any key to dismiss"));
  return lines;
}

function renderStatusBar(width) {
  const parts = [];
  if (state.phase === "streaming") parts.push("⏳ streaming");
  if (state.phase === "compacting") parts.push("🗑 compacting");
  if (state.phase === "retrying") parts.push("🔄 retrying");
  if (state.error) parts.push(`❌ ${state.error}`);
  const toolCount = Object.keys(state.toolExecutions).length;
  const running = Object.values(state.toolExecutions).filter((t) => t.status === "running").length;
  if (toolCount > 0) parts.push(`🔧 ${toolCount} tools${running > 0 ? ` (${running} running)` : ""}`);
  if (parts.length === 0) parts.push("ready");
  parts.push("Esc=abort");
  return chalk.dim(`┌${"─".repeat(width - 2)}┐`) + "\n" +
    chalk.dim("│ ") + parts.join(" │ ") + chalk.dim(" │");
}

// ──── Main render ───────────────────────────────────────────────────────────

function buildLines(width) {
  const lines = [];
  lines.push(...renderHeader(width));

  if (state.overlay === "help") {
    lines.push(...renderHelpOverlay(width));
  } else if (state.overlay === "tools") {
    lines.push(...renderToolsOverlay(width));
  } else {
    lines.push(...renderMessages(width));
  }

  lines.push(renderStatusBar(width));
  lines.push(chalk.green("❯ ") + state.input + chalk.dim("█"));
  return lines;
}

// ──── App component (pi-tui Component interface) ────────────────────────────

class ShellApp {
  constructor() {
    this.focused = false;
  }

  render(width) {
    return buildLines(width);
  }

  handleInput(data) {
    if (state.overlay) {
      state.overlay = null;
      tui.requestRender();
      return;
    }

    // Parse key sequences
    if (data === "\r") {
      // Enter
      handleSubmit();
    } else if (data === "\x1b") {
      // Escape — abort
      try { session?.abort?.(); } catch {}
    } else if (data === "\x7f" || data === "\b") {
      // Backspace
      state.input = state.input.slice(0, -1);
      tui.requestRender();
    } else if (data.length === 1 && data.charCodeAt(0) >= 32) {
      // Printable character
      state.input += data;
      tui.requestRender();
    }
    // Ignore other escape sequences (arrows, etc.)
  }

  invalidate() {}
}

// ──── Command handling ──────────────────────────────────────────────────────

function handleSubmit() {
  const cmd = state.input.trim();
  state.input = "";

  if (!cmd) { tui.requestRender(); return; }

  if (cmd === "/exit" || cmd === "/quit") { cleanup(); return; }
  if (cmd === "/help") { state.overlay = "help"; tui.requestRender(); return; }
  if (cmd === "/clear") {
    state.messages = [];
    state.toolExecutions = {};
    tui.requestRender();
    return;
  }
  if (cmd === "/model") {
    const s = agent.store.getSnapshot();
    state.messages.push({ role: "system", text: `Model: ${s.provider}/${s.model}` });
    tui.requestRender();
    return;
  }
  if (cmd === "/tools") { state.overlay = "tools"; tui.requestRender(); return; }

  // Send to Pi
  state.messages.push({ role: "user", text: cmd });
  tui.requestRender();
  agent.actions.send(cmd).catch((err) => {
    state.error = err?.message || String(err);
    tui.requestRender();
  });
}

// ──── Store subscription ───────────────────────────────────────────────────

let agent = null;
let tui = null;
let session = null;

function syncFromStore() {
  if (!agent) return;
  const snap = agent.store.getSnapshot();
  state.phase = snap.phase;
  state.model = snap.model;
  state.provider = snap.provider;
  state.streamingText = snap.streamingText;
  state.toolExecutions = snap.toolExecutions;
  state.error = snap.error;
  // Sync messages (only add new ones to avoid duplicates)
  if (snap.messages.length > state.messages.length) {
    const newMsgs = snap.messages.slice(state.messages.length);
    for (const m of newMsgs) {
      // Avoid duplicating user messages we already pushed locally
      if (m.role !== "user" || state.messages[state.messages.length - 1]?.text !== m.text) {
        state.messages.push(m);
      }
    }
  }
  tui?.requestRender();
}

// ──── Boot ──────────────────────────────────────────────────────────────────

async function main() {
  const cwd = process.cwd();

  // Boot TUI
  const terminal = new ProcessTerminal();
  tui = new TUI(terminal);

  const app = new ShellApp();
  tui.addChild(app);
  tui.setFocus(app);

  // Boot Pi session
  try {
    agent = await createNextAgent(cwd);
    session = agent;

    // Subscribe to store changes
    agent.store.subscribe(syncFromStore);

    // Sync initial state
    syncFromStore();
    state.phase = "ready";
    tui.requestRender();

    // Title
    process.stdout.write("\x1b]0;Jackal - Coding Agent\x07");
  } catch (err) {
    state.phase = "error";
    state.error = err?.message || String(err);
    tui.requestRender();
  }

  // Start rendering
  tui.start();
}

function cleanup() {
  if (agent) {
    agent.actions.dispose();
  }
  if (tui) {
    tui.stop();
  }
  process.exit(0);
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);

main().catch((err) => {
  console.error("Jackal failed to start:", err);
  process.exit(1);
});
