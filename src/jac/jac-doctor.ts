// Jac environment detection — binary, version, project layout, MCP availability.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { extname, join, relative } from "node:path";
import { findJacBinary } from "./jac-cli.js";
import { loadProjectConfig } from "../config/project-config.js";

const execFileAsync = promisify(execFile);

export interface JacDoctorReport {
  jacBinary: string | null;
  jacVersion: string | null;
  mcpAvailable: boolean;
  mcpDetail: string;
  jacTomlPath: string | null;
  jacTomlEntryPoint: string | null;
  jackalConfigPath: string | null;
  projectConfig: ReturnType<typeof loadProjectConfig>;
  jacFiles: string[];
  summary: string;
}

function findJacToml(cwd: string): string | null {
  let cur = cwd;
  while (true) {
    const cand = join(cur, "jac.toml");
    if (existsSync(cand)) return cand;
    const parent = join(cur, "..");
    if (parent === cur) return null;
    cur = parent;
  }
}

function parseJacTomlEntryPoint(jacTomlPath: string): string | null {
  try {
    const content = readFileSync(jacTomlPath, "utf-8");
    const quoted = content.match(/entry_point\s*=\s*["']([^"']+)["']/);
    if (quoted?.[1]) return quoted[1];
    const bare = content.match(/entry_point\s*=\s*(\S+)/);
    return bare?.[1]?.replace(/["']/g, "") ?? null;
  } catch {
    return null;
  }
}

function findJackalConfigPath(cwd: string): string | null {
  let cur = cwd;
  while (true) {
    const cand = join(cur, ".jackal");
    if (existsSync(cand)) return cand;
    const parent = join(cur, "..");
    if (parent === cur) return null;
    cur = parent;
  }
}

function walkJacFiles(cwd: string): string[] {
  const jacFiles: string[] = [];
  const skip = new Set([
    "node_modules",
    ".git",
    ".jac",
    "__pycache__",
    "dist",
    "build",
    "reference",
  ]);

  const walk = (dir: string, depth: number): void => {
    if (depth > 8 || jacFiles.length > 500) return;
    let entries: string[] = [];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.startsWith(".") && entry !== ".") continue;
      if (skip.has(entry)) continue;
      const full = join(dir, entry);
      let st;
      try {
        st = statSync(full);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        walk(full, depth + 1);
        continue;
      }
      if (extname(full) === ".jac") {
        jacFiles.push(relative(cwd, full).split("\\").join("/"));
      }
    }
  };

  walk(cwd, 0);
  jacFiles.sort();
  return jacFiles;
}

function formatProjectConfig(cfg: ReturnType<typeof loadProjectConfig>, configPath: string | null): string {
  const lines: string[] = [];
  lines.push(`config: ${configPath ?? "(no .jackal file — using defaults)"}`);
  lines.push(`  autocheck: ${cfg.autocheck ?? false}`);
  lines.push(`  autoformat: ${cfg.autoformat ?? false}`);
  lines.push(`  verbose: ${cfg.verbose ?? false}`);
  lines.push(`  plan: ${cfg.plan ?? false}`);
  lines.push(`  maxFixAttempts: ${cfg.maxFixAttempts ?? 3}`);
  lines.push(`  mermaid: ${cfg.mermaid ?? false}`);
  lines.push(`  notify: ${cfg.notify ?? false}`);
  lines.push(`  subagents: ${cfg.subagents ?? false}`);
  return lines.join("\n");
}

async function probeJacMcp(jacBinary: string): Promise<{ available: boolean; detail: string }> {
  try {
    await execFileAsync(jacBinary, ["mcp", "--inspect"], {
      timeout: 8_000,
      killSignal: "SIGKILL",
      maxBuffer: 512 * 1024,
    });
    return { available: true, detail: "jac mcp: available" };
  } catch {
    return {
      available: false,
      detail: "jac mcp: NOT available — `jac mcp` failed. Update jaclang.",
    };
  }
}

/** Run full Jac environment detection for `/jac-doctor`. */
export async function runJacDoctor(cwd: string): Promise<JacDoctorReport> {
  const jacBinary = findJacBinary();
  let jacVersion: string | null = null;
  let mcpAvailable = false;
  let mcpDetail = "jac mcp: NOT checked (no jac binary)";

  const jacTomlPath = findJacToml(cwd);
  const jacTomlEntryPoint = jacTomlPath ? parseJacTomlEntryPoint(jacTomlPath) : null;
  const jackalConfigPath = findJackalConfigPath(cwd);
  const projectConfig = loadProjectConfig(cwd);
  const jacFiles = walkJacFiles(cwd);

  if (jacBinary) {
    const [versionResult, mcpResult] = await Promise.all([
      execFileAsync(jacBinary, ["--version"], { timeout: 5_000, killSignal: "SIGKILL" })
        .then(({ stdout }) => stdout.trim())
        .catch(() => null),
      probeJacMcp(jacBinary),
    ]);
    jacVersion = versionResult;
    mcpAvailable = mcpResult.available;
    mcpDetail = mcpResult.detail;
  } else {
    mcpDetail = "jac mcp: NOT checked (jac binary missing)";
  }

  const lines: string[] = [];
  if (jacBinary) {
    lines.push(`jac binary: ${jacBinary}`);
    if (jacVersion) lines.push(`jac version: ${jacVersion}`);
  } else {
    lines.push("jac: NOT FOUND (install with: pip install jaclang)");
  }
  lines.push(mcpDetail);

  if (jacTomlPath) {
    lines.push(`jac.toml: ${relative(cwd, jacTomlPath).split("\\").join("/")}`);
    if (jacTomlEntryPoint) lines.push(`entry_point: ${jacTomlEntryPoint}`);
  } else {
    lines.push("jac.toml: not found");
  }

  lines.push("");
  lines.push(formatProjectConfig(projectConfig, jackalConfigPath));

  if (jacFiles.length > 0) {
    lines.push(`\n.jac files found: ${jacFiles.length}`);
    lines.push(jacFiles.slice(0, 20).map((f) => `  ${f}`).join("\n"));
    if (jacFiles.length > 20) lines.push(`  ... and ${jacFiles.length - 20} more`);
  } else {
    lines.push("\nNo .jac files found in project.");
  }

  return {
    jacBinary,
    jacVersion,
    mcpAvailable,
    mcpDetail,
    jacTomlPath,
    jacTomlEntryPoint,
    jackalConfigPath,
    projectConfig,
    jacFiles,
    summary: lines.join("\n"),
  };
}
