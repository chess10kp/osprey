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
  authStep: { kind: "idle" },
  toolExecutions: {},
  toolLastError: null,
};

let agent = null;
let tui = null;

function truncate(text, max = 120) {
  const str = String(text ?? "").replace(/\s+/g, " ").trim();
  return str.length > max ? `${str.slice(0, max - 1)}…` : str;
}

function renderToolTimeline() {
  const execs = Object.values(state.toolExecutions || {});
  if (!execs.length) return [];

  const lines = [chalk.magenta("Tools:")];
  for (const exec of execs.slice(-10)) {
    const icon = exec.status === "running" ? "⏳" : "✓";
    const input = exec.input ? ` in:${truncate(JSON.stringify(exec.input), 60)}` : "";
    const result = exec.result ? ` out:${truncate(exec.result, 80)}` : "";
    lines.push(chalk.magenta(`${icon} ${exec.toolName} [${exec.status}]${input}${result}`));
  }
  return lines;
}

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

  const toolLines = renderToolTimeline();
  if (toolLines.length) {
    lines.push("");
    lines.push(...toolLines);
  }

  if (state.authStep.kind !== "idle") {
    lines.push("");
    lines.push(chalk.yellow("Auth flow:"));
    for (const line of renderAuthStep(state.authStep)) lines.push(chalk.yellow(line));
  }

  const runningTools = Object.values(state.toolExecutions || {}).filter((t) => t.status === "running").length;
  const statusParts = [state.status, `tools:${runningTools}`, "/login", "/model", "/logout", "/abort", "/clear", "/exit"];
  if (state.toolLastError) statusParts.unshift(`tool-error: ${truncate(state.toolLastError, 60)}`);
  if (state.error) statusParts.unshift(`error: ${truncate(state.error, 60)}`);

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
  state.toolExecutions = snap.toolExecutions || {};
  const doneWithError = Object.values(state.toolExecutions).find((t) => t.status === "done" && typeof t.result === "string" && /\berror\b/i.test(t.result));
  state.toolLastError = doneWithError?.result || null;
  state.modelLabel = snap.model ? `${snap.provider}/${snap.model}` : "no model configured";
  state.status = snap.phase === "streaming" ? "responding" : "ready";
  tui?.requestRender();
}

function syncAuthFlow() {
  if (!agent) return;
  state.authStep = agent.authFlow.state.step;
  if (state.authStep.kind === "error") {
    state.error = state.authStep.message;
    state.status = "auth error";
  }
  tui?.requestRender();
}

function renderAuthStep(step) {
  switch (step.kind) {
    case "provider_picker":
      return [
        "Type provider id to login, or /cancel:",
        ...step.providers.map((p) => `- ${p.id} (${p.authType}) ${p.configured ? "configured" : "not configured"}`),
      ];
    case "logging_in":
      return [`${step.providerId}: ${step.status}`, "Use /cancel to abort login flow."];
    case "browser_auth":
      return [
        `Open browser for ${step.providerId}:`,
        step.url,
        step.instructions || "Complete auth, then return here.",
        "Use /cancel to abort login flow.",
      ];
    case "prompt":
      return [`${step.providerId}: ${step.message}`, "Type response and press Enter."];
    case "manual_code":
      return [`${step.providerId}: paste manual auth code and press Enter.`];
    case "select":
      return [
        `${step.providerId}: ${step.message}`,
        ...step.options.map((o) => `- ${o.id}: ${o.label}`),
        "Type option id and press Enter.",
      ];
    case "api_key_input":
      return [`${step.providerId}: enter API key and press Enter.`];
    case "logged_in":
      return [`Logged in: ${step.providerId}`, "Loading model picker..."];
    case "model_picker":
      return [
        "Type provider/model (e.g. anthropic/claude-sonnet-4), or /cancel:",
        ...step.models.map((m) => `- ${m.displayName}`),
      ];
    case "error":
      return [`Error: ${step.message}`, "Use /login to retry."];
    default:
      return [];
  }
}

function routeAuthInput(input) {
  const step = state.authStep;
  if (!step || step.kind === "idle") return false;

  switch (step.kind) {
    case "provider_picker":
      agent.authActions.loginWith(input);
      state.status = `login: ${input}`;
      tui.requestRender();
      return true;
    case "prompt":
    case "manual_code":
      agent.authActions.submitAuthPrompt(input);
      state.status = "submitted auth input";
      tui.requestRender();
      return true;
    case "select":
      agent.authActions.submitAuthSelect(input);
      state.status = "submitted auth selection";
      tui.requestRender();
      return true;
    case "api_key_input":
      agent.authActions.submitApiKey(input);
      state.status = "submitted api key";
      tui.requestRender();
      return true;
    case "model_picker": {
      const [provider, modelId] = input.split("/");
      if (!provider || !modelId) {
        state.status = "enter provider/model";
        tui.requestRender();
        return true;
      }
      agent.actions.setModel(provider, modelId).then(() => {
        state.status = `model set: ${provider}/${modelId}`;
        tui.requestRender();
      }).catch((err) => {
        state.error = err?.message || String(err);
        state.status = "error";
        tui.requestRender();
      });
      return true;
    }
    default:
      return false;
  }
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

  if (cmd === "/cancel") {
    agent.authActions.cancelLogin();
    state.status = "auth cancelled";
    tui.requestRender();
    return;
  }

  if (cmd === "/clear") {
    state.messages = [];
    state.streamingText = null;
    state.toolExecutions = {};
    state.toolLastError = null;
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

  if (cmd.startsWith("/login")) {
    const provider = cmd.split(/\s+/, 2)[1];
    if (provider) agent.authActions.loginWith(provider);
    else agent.authActions.login();
    state.status = "auth login";
    tui.requestRender();
    return;
  }

  if (cmd.startsWith("/logout")) {
    const provider = cmd.split(/\s+/, 2)[1];
    if (!provider) {
      state.status = "usage: /logout <provider>";
      tui.requestRender();
      return;
    }
    agent.authActions.logout(provider);
    state.status = `logged out ${provider}`;
    tui.requestRender();
    return;
  }

  if (cmd.startsWith("/model")) {
    const value = cmd.split(/\s+/, 2)[1];
    if (!value) {
      const models = agent.authActions.listModels();
      agent.authFlow.openModelPicker(models);
      state.status = "model picker";
      tui.requestRender();
      return;
    }
    const [provider, modelId] = value.split("/");
    if (!provider || !modelId) {
      state.status = "usage: /model <provider/model>";
      tui.requestRender();
      return;
    }
    agent.actions.setModel(provider, modelId).then(() => {
      state.status = `model set: ${provider}/${modelId}`;
      tui.requestRender();
    }).catch((err) => {
      state.error = err?.message || String(err);
      state.status = "error";
      tui.requestRender();
    });
    return;
  }

  if (routeAuthInput(cmd)) return;

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
    agent.authFlow.subscribe(syncAuthFlow);
    syncFromStore();
    syncAuthFlow();
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
