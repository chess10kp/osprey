// Session-scoped tool permissions — remember user grants for the current session.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { JackalProjectConfig } from "../config/project-config.js";
import { shouldAutoApprove, type DevMode } from "./dev-mode.js";

/** In-memory grants for the current agent session (cleared on /new or /resume). */
export class SessionPermissions {
  private _granted = new Set<string>();

  grant(toolName: string): void {
    const name = toolName.trim();
    if (name) this._granted.add(name);
  }

  isGranted(toolName: string): boolean {
    return this._granted.has(toolName);
  }

  clear(): void {
    this._granted.clear();
  }

  /** Snapshot of granted tool names (for debugging / UI). */
  grantedTools(): string[] {
    return [...this._granted].sort();
  }
}

/** Load persistent always-allow tool names from `.jackal` and `pi/mcp.json`. */
export function loadAlwaysAllowTools(
  cwd: string,
  projectConfig: JackalProjectConfig = {},
): Set<string> {
  const allowed = new Set<string>();

  if (Array.isArray(projectConfig.alwaysAllow)) {
    for (const name of projectConfig.alwaysAllow) {
      if (typeof name === "string" && name.trim()) allowed.add(name.trim());
    }
  }

  const mcpPath = join(cwd, "pi", "mcp.json");
  if (existsSync(mcpPath)) {
    try {
      const cfg = JSON.parse(readFileSync(mcpPath, "utf-8")) as {
        mcpServers?: Record<string, { alwaysAllow?: string[] }>;
      };
      for (const server of Object.values(cfg.mcpServers ?? {})) {
        if (!Array.isArray(server.alwaysAllow)) continue;
        for (const name of server.alwaysAllow) {
          if (typeof name === "string" && name.trim()) allowed.add(name.trim());
        }
      }
    } catch {
      // ignore invalid mcp.json
    }
  }

  return allowed;
}

export function isAlwaysAllowedTool(toolName: string, alwaysAllow: ReadonlySet<string>): boolean {
  return alwaysAllow.has(toolName);
}

/**
 * Whether a tool call should block for user confirmation.
 * Order: config/MCP alwaysAllow → session grant → dev mode policy.
 */
export function needsToolApproval(
  mode: DevMode,
  toolName: string,
  params: Record<string, unknown>,
  options: {
    sessionPermissions?: SessionPermissions;
    alwaysAllow?: ReadonlySet<string>;
  } = {},
): boolean {
  const alwaysAllow = options.alwaysAllow;
  if (alwaysAllow?.has(toolName)) return false;

  if (options.sessionPermissions?.isGranted(toolName)) return false;

  return !shouldAutoApprove(mode, toolName, params);
}
