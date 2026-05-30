import type { DevMode } from "../agent/dev-mode.js";
import {
  bridgeLoadProjectConfigSync,
  bridgeBootBatchSync,
  bridgeResolveDefaultModeSync,
} from "../jac/jac-bridge.js";

export interface JackalSubagentsConfig {
  model?: string;
  enabled?: boolean;
  [agentName: string]: string | { model?: string } | boolean | undefined;
}

export type PatternType = "glob" | "regex" | "exact" | "prefix";

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

export interface JackalProjectConfig {
  autocheck?: boolean;
  autoformat?: boolean;
  verbose?: boolean;
  plan?: boolean;
  /** Default development mode (overridden by `--mode` CLI flag). */
  mode?: DevMode;
  maxFixAttempts?: number;
  mermaid?: boolean;
  notify?: boolean;
  subagents?: boolean | JackalSubagentsConfig;
  /** Override model context window (tokens) for `/usage` and auto-compact. */
  contextMax?: number;
  sessions?: {
    autoSave?: boolean;
    saveIntervalMs?: number;
    /** Maximum number of sessions to keep (oldest pruned on startup). */
    maxCount?: number;
    /** Prune sessions older than this many days. */
    retentionDays?: number;
  };
  /** Tool names that never require approval (also see `alwaysAllow` in pi/mcp.json). */
  alwaysAllow?: string[];
  /** Structured permission patterns for fine-grained allow/deny rules. */
  permissionPatterns?: PermissionPatternConfig[];
  /** Auto-compact context when usage exceeds threshold. */
  autoCompact?: boolean | {
    enabled?: boolean;
    /** Trigger at this percent (default 80). */
    thresholdPercent?: number;
    /** Keep this many recent messages (default 12). */
    keepTail?: number;
    /** Notify the user when auto-compact runs (default true). */
    notify?: boolean;
    /** `llm` (default) or `mechanical` compaction strategy. */
    strategy?: "llm" | "mechanical";
  };
  /** Session-wide default compaction strategy for `/compact` and auto-compact. */
  compactStrategy?: "llm" | "mechanical";
}

/** Resolve boot mode from `.jackal` (`mode` key, legacy `plan: true`). */
export function resolveDefaultMode(config: JackalProjectConfig): DevMode {
  // Delegate to Python toolchain via bridge (sync)
  const mode = bridgeResolveDefaultModeSync(
    config as Record<string, unknown>,
  );
  return mode as DevMode;
}

export function loadProjectConfig(cwd: string): JackalProjectConfig {
  // Delegate walk-up + JSON parse to Python toolchain via bridge (sync)
  const raw = bridgeLoadProjectConfigSync(cwd);
  return raw as JackalProjectConfig;
}

export interface BootBatchResult {
  projectConfig: JackalProjectConfig;
  bootMode: DevMode;
  contextMax: number | null;
}

export function loadBootBatch(cwd: string): BootBatchResult {
  const raw = bridgeBootBatchSync(cwd);
  return {
    projectConfig: raw.projectConfig as JackalProjectConfig,
    bootMode: raw.bootMode as DevMode,
    contextMax: raw.contextMax,
  };
}
