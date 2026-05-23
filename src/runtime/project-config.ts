import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import type { DevMode } from "./dev-mode.js";

export interface JackalSubagentsConfig {
  model?: string;
  enabled?: boolean;
  [agentName: string]: string | { model?: string } | boolean | undefined;
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
  };
}

/** Resolve boot mode from `.jackal` (`mode` key, legacy `plan: true`). */
export function resolveDefaultMode(config: JackalProjectConfig): DevMode {
  if (config.mode && isDevMode(config.mode)) {
    return config.mode;
  }
  if (config.plan) {
    return "plan";
  }
  return "normal";
}

function isDevMode(value: string): value is DevMode {
  return value === "normal" || value === "auto-accept" || value === "yolo" || value === "plan";
}

function findConfigPath(cwd: string): string | null {
  let cur = resolve(cwd);
  while (true) {
    const cand = join(cur, ".jackal");
    if (existsSync(cand)) return cand;
    const parent = dirname(cur);
    if (parent === cur) return null;
    cur = parent;
  }
}

export function loadProjectConfig(cwd: string): JackalProjectConfig {
  const path = findConfigPath(cwd);
  if (!path) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf-8"));
    return parsed && typeof parsed === "object" ? (parsed as JackalProjectConfig) : {};
  } catch {
    return {};
  }
}
