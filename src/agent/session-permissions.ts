// Session-scoped tool permissions — remember user grants for the current session.
// Extended with pattern-based allowlists (glob, regex, exact, prefix).
//
// Pattern matching and evaluation delegated to
// lib/jac/agent/_session_permissions_toolchain.py via bridge.
// SessionPermissions class and approval helpers remain local (hot path, stateful).

import type { JackalProjectConfig } from "../config/project-config.js";
import { shouldAutoApprove, type DevMode } from "./dev-mode.js";
import {
  bridgeMatchPattern,
  bridgeEvaluatePermissionPatterns,
  bridgeLoadAlwaysAllowTools,
  bridgeLoadPermissionPatterns,
} from "../jac/jac-bridge.js";

// ---------------------------------------------------------------------------
// Pattern types
// ---------------------------------------------------------------------------

/** Pattern matching mode. */
export type PatternType = "glob" | "regex" | "exact" | "prefix";

/** A structured permission pattern. */
export interface PermissionPattern {
  /** Tool name or "*" for all tools. */
  tool: string;
  /** Pattern string — interpreted according to `type`. */
  pattern: string;
  /** How to match the pattern against the resource. */
  type: PatternType;
  /** "allow" | "deny" — deny takes precedence when both match. */
  action: "allow" | "deny";
}

/** A pending approval request in the session queue. */
export interface PendingApproval {
  id: string;
  toolName: string;
  resource: string;
  contentPreview: string;
  state: "pending" | "approved" | "denied" | "expired";
  createdAt: number;
  resolvedAt?: number;
  resolution?: string;
}

// ---------------------------------------------------------------------------
// Pattern matching engine
// ---------------------------------------------------------------------------

/**
 * Match a resource string against a pattern using the given mode.
 *
 * - `glob`   — fnmatch-style wildcards (*, ?, [abc]) — default
 * - `regex`  — JavaScript RegExp test against resource
 * - `exact`  — strict string equality
 * - `prefix` — resource starts with pattern
 */
export function matchPattern(resource: string, pattern: string, type: PatternType = "glob"): boolean {
  return bridgeMatchPattern(resource, pattern, type);
}

// globToRegex / escapeRegex moved to Python toolchain — kept locally only if needed for SessionPermissions class

// ---------------------------------------------------------------------------
// Session permissions (in-memory grants)
// ---------------------------------------------------------------------------

/** In-memory grants for the current agent session (cleared on /new or /resume). */
export class SessionPermissions {
  private _granted = new Set<string>();
  /** Pattern-based grants: tool → patterns */
  private _patternGrants: Map<string, PermissionPattern[]> = new Map();

  grant(toolName: string): void {
    const name = toolName.trim();
    if (name) this._granted.add(name);
  }

  isGranted(toolName: string): boolean {
    return this._granted.has(toolName);
  }

  /** Grant a pattern-based allow for a tool. */
  grantPattern(tool: string, pattern: string, type: PatternType = "glob"): void {
    const existing = this._patternGrants.get(tool) ?? [];
    // Avoid duplicates
    if (!existing.some((p) => p.pattern === pattern && p.type === type)) {
      existing.push({ tool, pattern, type, action: "allow" });
      this._patternGrants.set(tool, existing);
    }
  }

  /** Check if a tool+resource is granted by any pattern. */
  isGrantedByPattern(toolName: string, resource: string): boolean {
    // Check all pattern grants — both tool-specific and wildcard
    for (const [tool, patterns] of this._patternGrants) {
      // Tool must match: either exact match or wildcard "*"
      if (tool !== "*" && tool !== toolName) continue;
      for (const p of patterns) {
        if (matchPattern(resource, p.pattern, p.type)) {
          return true;
        }
      }
    }
    return false;
  }

  clear(): void {
    this._granted.clear();
    this._patternGrants.clear();
  }

  /** Snapshot of granted tool names (for debugging / UI). */
  grantedTools(): string[] {
    return [...this._granted].sort();
  }

  /** Snapshot of pattern-based grants. */
  grantedPatterns(): Map<string, PermissionPattern[]> {
    return new Map(this._patternGrants);
  }
}

// ---------------------------------------------------------------------------
// Pattern-based allowlist config
// ---------------------------------------------------------------------------

/** Config format for `.jackal` permissionPatterns. */
export interface PermissionPatternConfig {
  /** Tool name or "*" for all tools. */
  tool: string;
  /** Pattern to match against the resource (command, path, etc.). */
  pattern: string;
  /** Pattern type: "glob" (default), "regex", "exact", "prefix". */
  type?: PatternType;
  /** Action: "allow" (default) or "deny". Deny takes precedence. */
  action?: "allow" | "deny";
}

/** Load permission patterns from project config. */
export function loadPermissionPatterns(
  projectConfig: JackalProjectConfig = {},
): PermissionPattern[] {
  return bridgeLoadPermissionPatterns(
    projectConfig as Record<string, unknown>,
  ) as unknown as PermissionPattern[];
}

/** Load persistent always-allow tool names from `.jackal` and `pi/mcp.json`. */
export function loadAlwaysAllowTools(
  cwd: string,
  projectConfig: JackalProjectConfig = {},
): Set<string> {
  return new Set(bridgeLoadAlwaysAllowTools(cwd, projectConfig as Record<string, unknown>));
}

export function isAlwaysAllowedTool(toolName: string, alwaysAllow: ReadonlySet<string>): boolean {
  return alwaysAllow.has(toolName);
}

// ---------------------------------------------------------------------------
// Approval queue
// ---------------------------------------------------------------------------

let approvalCounter = 0;

/** Create a pending approval entry. */
export function createPendingApproval(
  toolName: string,
  resource: string,
  contentPreview: string = "",
): PendingApproval {
  return {
    id: `approval-${Date.now()}-${++approvalCounter}`,
    toolName,
    resource,
    contentPreview: contentPreview.slice(0, 512),
    state: "pending",
    createdAt: Date.now(),
  };
}

/** Check if an approval has expired (default 5 minutes). */
export function isApprovalExpired(approval: PendingApproval, maxAgeMs: number = 300_000): boolean {
  return approval.state === "pending" && Date.now() - approval.createdAt > maxAgeMs;
}

// ---------------------------------------------------------------------------
// Main permission check
// ---------------------------------------------------------------------------

/**
 * Evaluate permission patterns for a tool+resource.
 *
 * Resolution order:
 *   1. Deny patterns (any matching deny → deny immediately)
 *   2. Config/MCP alwaysAllow (exact tool names)
 *   3. Allow patterns (matching allow → allow)
 *   4. Session grants (exact or pattern-based)
 *   5. Dev mode policy
 *
 * Returns: "allow" | "deny" | "ask"
 */
export function evaluatePermissionPatterns(
  patterns: PermissionPattern[],
  toolName: string,
  resource: string,
): "allow" | "deny" | null {
  return bridgeEvaluatePermissionPatterns(
    patterns as unknown as Array<Record<string, unknown>>,
    toolName,
    resource,
  ) as "allow" | "deny" | null;
}

/**
 * Whether a tool call should block for user confirmation.
 * Order: pattern deny → pattern allow → config/MCP alwaysAllow → session grant → dev mode policy.
 */
export function needsToolApproval(
  mode: DevMode,
  toolName: string,
  params: Record<string, unknown>,
  options: {
    sessionPermissions?: SessionPermissions;
    alwaysAllow?: ReadonlySet<string>;
    /** Structured permission patterns from .jackal config. */
    permissionPatterns?: PermissionPattern[];
    /** Resource string to match against (e.g. command, file path). */
    resource?: string;
  } = {},
): boolean {
  const resource = options.resource ?? extractResource(toolName, params);

  // 1. Check structured permission patterns
  if (options.permissionPatterns && options.permissionPatterns.length > 0) {
    const patternResult = evaluatePermissionPatterns(
      options.permissionPatterns,
      toolName,
      resource,
    );
    if (patternResult === "deny") return true;  // Deny always requires no approval — it's blocked
    if (patternResult === "allow") return false; // Allow bypasses approval
  }

  // 2. Config/MCP alwaysAllow (exact tool names)
  const alwaysAllow = options.alwaysAllow;
  if (alwaysAllow?.has(toolName)) return false;

  // 3. Session grants (exact or pattern-based)
  if (options.sessionPermissions?.isGranted(toolName)) return false;
  if (options.sessionPermissions?.isGrantedByPattern(toolName, resource)) return false;

  // 4. Dev mode policy
  return !shouldAutoApprove(mode, toolName, params);
}

/**
 * Extract a resource string from tool params for pattern matching.
 * For bash: the command. For write/edit: the file path. For MCP: server.tool.
 * Exported for use by agent-session.
 */
export function extractResource(
  toolName: string,
  params: Record<string, unknown>,
): string {
  if (toolName === "bash" || toolName === "jac_cli") {
    if (typeof params.command === "string") return params.command;
    if (Array.isArray(params.args)) return `jac ${(params.args as string[]).join(" ")}`;
    return "";
  }
  if (toolName === "write" || toolName === "edit") {
    return typeof params.path === "string" ? params.path : "";
  }
  if (toolName === "mcp") {
    const server = typeof params.server_name === "string" ? params.server_name : "";
    const tool = typeof params.tool_name === "string" ? params.tool_name : "";
    return `${server}:${tool}`;
  }
  return "";
}
