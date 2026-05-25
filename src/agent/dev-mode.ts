// Development modes — tool approval policy and plan-mode tool filtering.

import { loadProjectConfig, resolveDefaultMode } from "../config/project-config.js";

export type DevMode = "normal" | "auto-accept" | "yolo" | "plan";

export const DEV_MODES: readonly DevMode[] = ["normal", "auto-accept", "yolo", "plan"];

/**
 * Tools that modify project files — blocked in plan mode.
 * All other registered tools (read, bash, LSP, Jac MCP reads, subagents, etc.) stay available.
 */
export const PLAN_MODE_BLOCKED_TOOLS = new Set([
  "write",
  "edit",
  "jac_format",
  "jac_fix",
  "jac_create",
  "create_task",
  "update_task",
  "delete_task",
  // Jac MCP tools that write or run arbitrary mutating commands
  "format_jac",
  "execute_command",
]);

export const PLAN_MODE_SYSTEM_APPENDIX = `

## Plan mode (active)

You are in **plan mode**: explore, analyze, and produce a clear implementation plan. You must **not** modify project source files.

- Use read, search, diagnostics, \`jac check\`, tests, bash, LSP, and MCP read tools freely.
- Do **not** call \`write\`, \`edit\`, format/fix/create tools, or task mutations — they are blocked.
- Output a numbered plan the user can approve; tell them to switch out of plan mode (Shift+Tab) to implement.
`;

export function planModeBlockReason(toolName: string): string {
  return `Tool "${toolName}" cannot modify files in plan mode. Switch to normal mode (Shift+Tab) to implement changes.`;
}

export function isToolBlockedInPlanMode(toolName: string): boolean {
  return PLAN_MODE_BLOCKED_TOOLS.has(toolName);
}

export function cycleMode(current: DevMode): DevMode {
  const idx = DEV_MODES.indexOf(current);
  const next = idx < 0 ? 0 : (idx + 1) % DEV_MODES.length;
  return DEV_MODES[next]!;
}

export function parseModeFlag(
  args: string[],
): DevMode | undefined | { error: string } {
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    let raw: string | undefined;

    if (arg === "--mode" && args[i + 1]) {
      raw = args[i + 1];
    } else if (arg?.startsWith("--mode=")) {
      raw = arg.slice("--mode=".length);
    }

    if (raw === undefined) continue;

    if ((DEV_MODES as readonly string[]).includes(raw)) {
      return raw as DevMode;
    }
    return { error: raw };
  }
  return undefined;
}

export function isToolAllowedInPlanMode(toolName: string): boolean {
  return !isToolBlockedInPlanMode(toolName);
}

export function systemPromptForMode(basePrompt: string, mode: DevMode): string {
  if (mode !== "plan") return basePrompt;
  if (basePrompt.includes("## Plan mode (active)")) return basePrompt;
  return basePrompt + PLAN_MODE_SYSTEM_APPENDIX;
}

/**
 * Detect bash/git commands that should never auto-run (even in auto-accept).
 */
export function isDestructiveBash(cmd: string): boolean {
  const command = cmd.trim();
  if (!command) return false;

  const dangerous = [
    /rm\s+-rf\s+\/(?!\w)/i,
    /\brm\s+-rf\s+~\b/i,
    /\brm\s+-rf\s+\$\{?HOME\}?/i,
    /\bmkfs\b/i,
    /\bdd\s+if=/i,
    /:()\{:\|:&\};:/,
    />\s*\/dev\/sd[a-z]/i,
    /\bchmod\s+-R\s+000\b/i,
    /\bgit\s+reset\s+--hard\b/i,
    /\bgit\s+push\s+(--force|-f)\b/i,
    /\bgit\s+clean\s+-[a-z]*f/i,
    /\bgit\s+branch\s+-[dD]\s+/i,
    /\bgit\s+stash\s+(drop|clear)\b/i,
    /\bgit\s+reflog\s+expire\b/i,
    /\bgit\s+filter-branch\b/i,
    /\bdrop\s+database\b/i,
    /\btruncate\s+table\b/i,
  ];

  return dangerous.some((pattern) => pattern.test(command));
}

function bashCommandFromParams(toolName: string, params: Record<string, unknown>): string {
  if (toolName === "bash") {
    return String(params.command ?? "");
  }
  if (toolName === "jac_cli") {
    const args = params.args;
    if (Array.isArray(args)) {
      return `jac ${args.map(String).join(" ")}`;
    }
  }
  return "";
}

/**
 * Whether a tool call may run without user confirmation.
 */
export function shouldAutoApprove(
  mode: DevMode,
  toolName: string,
  params: Record<string, unknown>,
): boolean {
  if (mode === "yolo") return true;

  if (mode === "plan") {
    return !isToolBlockedInPlanMode(toolName);
  }

  if (mode === "auto-accept") {
    const shellCmd = bashCommandFromParams(toolName, params);
    if (shellCmd) {
      return !isDestructiveBash(shellCmd);
    }
    return true;
  }

  // normal — confirm every tool call
  return false;
}

/** Resolve boot mode: CLI flag → JACKAL_MODE env → `.jackal` config. */
export function resolveBootMode(cwd: string, cliMode?: DevMode): DevMode {
  if (cliMode) return cliMode;

  const env = process.env.JACKAL_MODE?.trim();
  if (env && (DEV_MODES as readonly string[]).includes(env)) {
    return env as DevMode;
  }

  return resolveDefaultMode(loadProjectConfig(cwd));
}
