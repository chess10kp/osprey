// ────────────────────────────────────────────────────────────────────────────
// Project .jackal config — reads a per-project .jackal file from the CWD.
//
// The .jackal file is a JSON file that lets users enable/disable Jackal
// features per project. It's read once at session_start and cached.
//
// Supported keys:
//   autocheck        boolean   auto-run jac check after write/edit   (default: true)
//   verbose          boolean   show full jac check output            (default: false)
//   plan             boolean   start in plan mode                    (default: false)
//   maxFixAttempts   number    max auto-fix retries per file         (default: 2)
//   mermaid          boolean   enable pi-mermaid rendering           (default: true)
//   notify           boolean   enable @pi-unipi/notify               (default: true)
//   subagents        object    subagent config overrides
//     model          string    default model for all subagents
//     scout.model    string    model for scout agent
//     worker.model   string    model for worker agent
//     planner.model  string    model for planner agent
//
// Example .jackal:
//   {
//     "autocheck": false,
//     "verbose": true,
//     "maxFixAttempts": 3,
//     "mermaid": true,
//     "notify": true,
//     "subagents": {
//       "model": "openai-codex/gpt-5.3-codex",
//       "scout": { "model": "anthropic/claude-haiku-4-5" },
//       "worker": { "model": "openai-codex/gpt-5.4-mini" }
//     }
//   }
//
// Cross-platform: works on Linux, macOS, and Windows. Uses node:path for
// separators, normalize() for root detection, and accepts both .jackal and
// _jackal on Windows (where dotfiles can be awkward in some tools).
// ────────────────────────────────────────────────────────────────────────────

import { existsSync, readFileSync } from "node:fs";
import { join, normalize, dirname, parse as parsePath } from "node:path";

/** Config file name — .jackal everywhere, _jackal also checked on Windows. */
const CONFIG_FILENAME = ".jackal";
const CONFIG_FILENAME_ALT = "_jackal";

/** Shape of a .jackal project config file. */
export interface JackalProjectConfig {
  /** Auto-run jac check after every write/edit of a .jac file. */
  autocheck?: boolean;
  /** Show full jac check output and per-attempt detail. */
  verbose?: boolean;
  /** Start in plan mode (read-only exploration). */
  plan?: boolean;
  /** Max auto-fix retries per file before giving up. */
  maxFixAttempts?: number;
  /** Enable pi-mermaid diagram rendering. */
  mermaid?: boolean;
  /** Enable @pi-unipi/notify notifications. */
  notify?: boolean;
  /** Subagent model overrides. */
  subagents?: {
    /** Default model for all subagents. */
    model?: string;
    /** Per-agent overrides. */
    [agent: string]: string | { model?: string } | undefined;
  };
}

/** Resolved (fully-populated) config with defaults applied. */
export interface ResolvedJackalConfig {
  autocheck: boolean;
  verbose: boolean;
  plan: boolean;
  maxFixAttempts: number;
  mermaid: boolean;
  notify: boolean;
  subagents: NonNullable<JackalProjectConfig["subagents"]>;
  /** Absolute path the config was loaded from, or null if no file found. */
  configPath: string | null;
}

const DEFAULTS: ResolvedJackalConfig = {
  autocheck: true,
  verbose: false,
  plan: false,
  maxFixAttempts: 2,
  mermaid: true,
  notify: true,
  subagents: {},
  configPath: null,
};

/** Cached config for the current session. */
let cachedConfig: ResolvedJackalConfig | null = null;

/**
 * Check whether we're running on Windows.
 * Handles both `win32` and `cygwin`/`msys` (Git Bash) environments.
 */
function isWindows(): boolean {
  if (process.platform === "win32") return true;
  // Git Bash / MSYS / Cygwin
  const ostype = process.env.OSTYPE;
  if (ostype && /^(cygwin|msys)/.test(ostype)) return true;
  return false;
}

/**
 * Get the filesystem root for the given path.
 * On Windows, this is the drive root (e.g. "C:\").
 * On POSIX, this is "/".
 */
function getRoot(path: string): string {
  const parsed = parsePath(path);
  return parsed.root;
}

/**
 * Check if two paths represent the same directory after normalization.
 * Cross-platform: handles both forward and backslash separators.
 */
function sameDirectory(a: string, b: string): boolean {
  return normalize(a) === normalize(b);
}

/**
 * Search for a .jackal config file starting from `cwd`, walking up to root.
 * On Windows, also checks for _jackal as an alternative to .jackal.
 * Returns the absolute path if found, or null.
 */
export function findJackalConfig(cwd: string): string | null {
  const root = getRoot(cwd);
  let dir = normalize(cwd);
  const win = isWindows();
  const filenames = win ? [CONFIG_FILENAME, CONFIG_FILENAME_ALT] : [CONFIG_FILENAME];

  for (let i = 0; i < 40; i++) {
    for (const name of filenames) {
      const candidate = join(dir, name);
      if (existsSync(candidate)) return candidate;
    }
    // Reached filesystem root — stop
    if (sameDirectory(dir, root)) break;
    const parent = normalize(dirname(dir));
    // dirname("/") === "/", dirname("C:\") === "C:\" — detect no-progress
    if (sameDirectory(parent, dir)) break;
    dir = parent;
  }
  return null;
}

/**
 * Read and parse a .jackal config file, returning a partial config.
 * Returns null if the file doesn't exist or can't be parsed.
 * On parse errors, logs a warning but does not throw.
 */
export function readJackalConfig(configPath: string): JackalProjectConfig | null {
  try {
    const raw = readFileSync(configPath, "utf8");
    // Strip BOM if present (common on Windows when editors save UTF-8 with BOM)
    const stripped = raw.replace(/^\uFEFF/, "");
    return JSON.parse(stripped) as JackalProjectConfig;
  } catch {
    return null;
  }
}

/**
 * Resolve a partial config into a fully-populated config with defaults.
 */
export function resolveConfig(partial: JackalProjectConfig, configPath: string | null): ResolvedJackalConfig {
  return {
    autocheck: partial.autocheck ?? DEFAULTS.autocheck,
    verbose: partial.verbose ?? DEFAULTS.verbose,
    plan: partial.plan ?? DEFAULTS.plan,
    maxFixAttempts: partial.maxFixAttempts ?? DEFAULTS.maxFixAttempts,
    mermaid: partial.mermaid ?? DEFAULTS.mermaid,
    notify: partial.notify ?? DEFAULTS.notify,
    subagents: partial.subagents ?? { ...DEFAULTS.subagents },
    configPath,
  };
}

/**
 * Load the .jackal config for the given cwd.
 * Walks up from cwd to find .jackal, parses it, applies defaults, and caches.
 * Call this once at session_start. Call clearConfig() at session_shutdown.
 */
export function loadProjectConfig(cwd: string): ResolvedJackalConfig {
  if (cachedConfig) return cachedConfig;

  const configPath = findJackalConfig(cwd);
  if (!configPath) {
    cachedConfig = { ...DEFAULTS, configPath: null };
    return cachedConfig;
  }

  const partial = readJackalConfig(configPath);
  if (!partial) {
    cachedConfig = { ...DEFAULTS, configPath };
    return cachedConfig;
  }

  cachedConfig = resolveConfig(partial, configPath);
  return cachedConfig;
}

/**
 * Get the cached config (must call loadProjectConfig first).
 * Returns defaults if nothing is cached.
 */
export function getConfig(): ResolvedJackalConfig {
  return cachedConfig ?? { ...DEFAULTS, configPath: null };
}

/**
 * Clear the cached config (call at session_shutdown).
 */
export function clearConfig(): void {
  cachedConfig = null;
}

/**
 * Format the config for display (e.g. in /jac-doctor).
 */
export function formatConfig(config: ResolvedJackalConfig): string {
  const lines: string[] = [];
  lines.push(`config: ${config.configPath ?? "(no .jackal file — using defaults)"}`);
  lines.push(`  autocheck: ${config.autocheck}`);
  lines.push(`  verbose: ${config.verbose}`);
  lines.push(`  plan: ${config.plan}`);
  lines.push(`  maxFixAttempts: ${config.maxFixAttempts}`);
  lines.push(`  mermaid: ${config.mermaid}`);
  lines.push(`  notify: ${config.notify}`);

  const subagents = config.subagents;
  const keys = Object.keys(subagents).filter((k) => k !== "model");
  if (subagents.model || keys.length > 0) {
    lines.push("  subagents:");
    if (subagents.model) {
      lines.push(`    default: ${subagents.model}`);
    }
    for (const agent of keys) {
      const val = subagents[agent];
      if (typeof val === "string") {
        lines.push(`    ${agent}: ${val}`);
      } else if (val && typeof val === "object" && "model" in val) {
        lines.push(`    ${agent}.model: ${val.model}`);
      }
    }
  }

  return lines.join("\n");
}
