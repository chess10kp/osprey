import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export interface JackalProjectConfig {
  autocheck?: boolean;
  autoformat?: boolean;
  verbose?: boolean;
  plan?: boolean;
  maxFixAttempts?: number;
  mermaid?: boolean;
  notify?: boolean;
  subagents?: boolean;
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
