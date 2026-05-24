// Headless `jackal run "prompt"` — non-interactive single-shot agent execution.

import { createNextAgent } from "../core/adapter.js";
import { isAgentBusy } from "../core/agent-busy.js";
import { type DevMode, DEV_MODES, parseModeFlag } from "../agent/dev-mode.js";

export interface RunCliOptions {
  prompt: string;
  plain?: boolean;
  mode?: DevMode;
  cwd?: string;
}

export interface RunCliResult {
  exitCode: number;
  /** Final assistant text (plain mode prints this to stdout). */
  output: string;
  error?: string;
}

/** Run mode default: auto-accept unless `--mode` or `JACKAL_MODE` is set. */
export function resolveRunMode(_cwd: string, cliMode?: DevMode): DevMode {
  if (cliMode) return cliMode;

  const env = process.env.JACKAL_MODE?.trim();
  if (env && (DEV_MODES as readonly string[]).includes(env)) {
    return env as DevMode;
  }

  // Explicit run default — differs from interactive boot (normal / .jackal).
  return "auto-accept";
}

export function parseRunArgs(
  argv: string[],
): { ok: true; options: RunCliOptions } | { ok: false; error: string } {
  const args = argv[0] === "run" ? argv.slice(1) : [...argv];

  const modeParsed = parseModeFlag(["dummy", ...args]);
  if (modeParsed && typeof modeParsed === "object" && "error" in modeParsed) {
    return {
      ok: false,
      error: `invalid --mode '${modeParsed.error}' (expected ${DEV_MODES.join(", ")})`,
    };
  }

  let plain = false;
  let mode: DevMode | undefined =
    modeParsed && typeof modeParsed === "string" ? modeParsed : undefined;
  const promptParts: string[] = [];

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;

    if (arg === "--plain") {
      plain = true;
      continue;
    }

    if (arg === "--mode") {
      i++;
      continue;
    }
    if (arg.startsWith("--mode=")) {
      continue;
    }

    if (arg.startsWith("-")) {
      return { ok: false, error: `unknown flag: ${arg}` };
    }

    promptParts.push(arg);
  }

  const prompt = promptParts.join(" ").trim();
  if (!prompt) {
    return { ok: false, error: "missing prompt (usage: jackal run [--plain] [--mode MODE] \"prompt\")" };
  }

  return { ok: true, options: { prompt, plain, mode } };
}

function formatToolLine(toolName: string, input?: Record<string, unknown>): string {
  if (toolName === "read") {
    const path = input?.path ?? input?.file_path;
    if (path) return `⚒ Read ${String(path)}`;
    return "⚒ Read file";
  }
  if (toolName === "write" || toolName === "edit") {
    const path = input?.path ?? input?.file_path;
    if (path) return `⚒ ${toolName === "write" ? "Write" : "Edit"} ${String(path)}`;
  }
  if (toolName === "bash" && input?.command) {
    const cmd = String(input.command);
    const short = cmd.length > 72 ? `${cmd.slice(0, 69)}...` : cmd;
    return `⚒ Bash ${short}`;
  }
  return `⚒ ${toolName}`;
}

function lastAssistantText(messages: { role: string; text: string }[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg?.role === "assistant" && msg.text.trim()) {
      return msg.text;
    }
  }
  return "";
}

function approvalMessage(toolName: string, subagentName?: string): string {
  if (subagentName) {
    return `Tool approval required for subagent '${subagentName}': ${toolName}`;
  }
  return `Tool approval required for: ${toolName}`;
}

/**
 * Headless run: boot agent, send prompt, wait for completion, print result, dispose.
 */
export async function runCli(options: RunCliOptions): Promise<RunCliResult> {
  const cwd = options.cwd ?? process.env.JACKAL_AGENT_CWD ?? process.cwd();
  const mode = resolveRunMode(cwd, options.mode);
  const plain = options.plain ?? false;

  let agent: Awaited<ReturnType<typeof createNextAgent>>;
  try {
    agent = await createNextAgent(cwd, { mode });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    return { exitCode: 1, output: "", error: message };
  }

  const { store, actions } = agent;
  let approvalBlocked = false;
  let blockedTool = "";
  let blockedSubagent = "";
  let streamedLen = 0;
  const printedTools = new Set<string>();
  let lastPhase = store.getSnapshot().phase;
  let exitArmed = false;
  let shuttingDown = false;

  const onSigint = (): void => {
    if (shuttingDown) {
      process.exit(130);
    }
    const snap = store.getSnapshot();
    if (isAgentBusy(snap)) {
      void actions.abort();
      if (!plain) {
        process.stderr.write("\nRun cancelled. Press Ctrl+C again to exit.\n");
      }
      exitArmed = false;
      return;
    }
    if (!exitArmed) {
      exitArmed = true;
      if (!plain) {
        process.stderr.write("\nPress Ctrl+C again to exit.\n");
      }
      return;
    }
    shuttingDown = true;
    actions.dispose();
    process.exit(130);
  };

  if (process.stdout.isTTY) {
    process.on("SIGINT", onSigint);
  }

  const writeStatus = (phase: string): void => {
    if (plain) return;
    const label =
      phase === "streaming"
        ? "Working…"
        : phase === "compacting"
          ? "Compacting…"
          : phase === "retrying"
            ? "Retrying…"
            : "";
    if (label) {
      process.stderr.write(`\r${label}\r`);
    }
  };

  const unsub = store.subscribe(() => {
    const snap = store.getSnapshot();

    if (snap.pendingSubagentApproval && !approvalBlocked) {
      approvalBlocked = true;
      blockedTool = snap.pendingSubagentApproval.toolName;
      blockedSubagent = snap.pendingSubagentApproval.subagentName;
      void actions.abort();
      return;
    }

    if (snap.pendingApproval && !approvalBlocked) {
      approvalBlocked = true;
      blockedTool = snap.pendingApproval.toolName;
      void actions.abort();
      return;
    }

    if (!plain) {
      if (snap.phase !== lastPhase) {
        writeStatus(snap.phase);
        lastPhase = snap.phase;
      }

      if (snap.streamingText !== null) {
        const delta = snap.streamingText.slice(streamedLen);
        if (delta) {
          process.stdout.write(delta);
          streamedLen = snap.streamingText.length;
        }
      } else {
        streamedLen = 0;
      }

      for (const [id, exec] of Object.entries(snap.toolExecutions)) {
        if (exec.status === "running" && !printedTools.has(id)) {
          printedTools.add(id);
          process.stdout.write(`${formatToolLine(exec.toolName, exec.input)}\n`);
        }
      }
    }
  });

  try {
    await actions.send(options.prompt);
  } catch (err: unknown) {
    unsub();
    actions.dispose();
    const message = err instanceof Error ? err.message : String(err);
    return { exitCode: 1, output: "", error: message };
  } finally {
    if (process.stdout.isTTY) {
      process.off("SIGINT", onSigint);
    }
  }

  unsub();

  const snap = store.getSnapshot();
  const pendingSubagent = snap.pendingSubagentApproval;
  const pendingTool =
    pendingSubagent?.toolName ?? snap.pendingApproval?.toolName ?? blockedTool;
  const blocked =
    approvalBlocked ||
    snap.pendingSubagentApproval !== null ||
    snap.pendingApproval !== null;

  if (blocked && pendingTool) {
    const subagentName = pendingSubagent?.subagentName || blockedSubagent || undefined;
    actions.dispose();
    return {
      exitCode: 1,
      output: plain ? "" : lastAssistantText(snap.messages),
      error: approvalMessage(pendingTool, subagentName),
    };
  }

  if (snap.error) {
    actions.dispose();
    return { exitCode: 1, output: "", error: snap.error };
  }

  const output = lastAssistantText(snap.messages);

  if (plain) {
    if (output) {
      process.stdout.write(`${output}\n`);
    }
  } else if (output && streamedLen === 0) {
    process.stdout.write(`${output}\n`);
  } else if (output && !process.stdout.writableEnded) {
    process.stdout.write("\n");
  }

  if (!plain) {
    process.stderr.write("\r\x1b[K");
  }

  actions.dispose();
  return { exitCode: 0, output };
}

/** Print CLI usage for `run` subcommand. */
export function printRunUsage(): void {
  console.error(`Usage: jackal run [--plain] [--mode MODE] "prompt"

  --plain          Minimal stdout (final assistant text only)
  --mode MODE      normal | auto-accept | yolo | plan (default: auto-accept)
                   Also respects JACKAL_MODE when --mode is omitted

Examples:
  jackal run "explain main.jac"
  jackal run --plain --mode plan "analyze auth flow"
  jackal --mode yolo run "update README"`);
}
