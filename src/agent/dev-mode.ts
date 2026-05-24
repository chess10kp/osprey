// Development modes — tool approval policy and plan-mode tool filtering.

import { loadProjectConfig, resolveDefaultMode } from "../config/project-config.js";

export type DevMode = "normal" | "auto-accept" | "yolo" | "plan";

export const DEV_MODES: readonly DevMode[] = ["normal", "auto-accept", "yolo", "plan"];

/** Read-only core tool + Jac MCP read tools allowed in plan mode. */
export const PLAN_MODE_TOOLS = new Set([
  "read",
  "agent",
  "validate_jac",
  "check_syntax",
  "search_docs",
  "get_ast",
  "graph_visualize",
  "explain_error",
  "get_resource",
  "list_examples",
  "get_example",
  "create_task",
  "update_task",
  "list_tasks",
  "delete_task",
]);

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
  return PLAN_MODE_TOOLS.has(toolName);
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
    return isToolAllowedInPlanMode(toolName);
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
