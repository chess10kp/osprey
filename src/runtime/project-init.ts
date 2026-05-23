// Project initializer — analyze a Jac project and generate AGENTS.md.

import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, resolve, relative, extname } from "node:path";
import { execSync } from "node:child_process";

export interface ProjectInfo {
  projectName: string;
  description: string;
  hasJacToml: boolean;
  jacTomlEntry: string | null;
  jacVersion: string | null;
  pythonVersion: string | null;
  jacFiles: string[];
  pythonFiles: string[];
  hasVenv: boolean;
  hasGit: boolean;
  hasTests: boolean;
  hasReadme: boolean;
  hasAgentsMd: boolean;
  hasJackalConfig: boolean;
  npmDeps: string[];
  projectType: ProjectType;
}

export type ProjectType =
  | "fullstack"
  | "api"
  | "client-only"
  | "library"
  | "mixed"
  | "non-jac";

const MAX_SCAN_DEPTH = 5;
const MAX_JAC_FILES = 100;

function runQuiet(cmd: string, cwd: string): string | null {
  try {
    return execSync(cmd, {
      cwd,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return null;
  }
}

function scanFiles(
  cwd: string,
  extensions: string[],
  maxDepth = MAX_SCAN_DEPTH,
): string[] {
  const results: string[] = [];

  function walk(dir: string, depth: number): void {
    if (depth > maxDepth || results.length >= MAX_JAC_FILES) return;

    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (results.length >= MAX_JAC_FILES) break;
      if (entry.name.startsWith(".") && entry.name !== ".jackal") continue;

      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        // Skip common non-project dirs
        if (
          entry.name === "node_modules" ||
          entry.name === "__pycache__" ||
          entry.name === ".git" ||
          entry.name === "dist" ||
          entry.name === ".venv" ||
          entry.name === "venv"
        )
          continue;
        walk(fullPath, depth + 1);
      } else if (entry.isFile()) {
        const ext = extname(entry.name);
        if (extensions.includes(ext)) {
          results.push(relative(cwd, fullPath));
        }
      }
    }
  }

  walk(cwd, 0);
  return results.sort();
}

function classifyProject(info: {
  jacFiles: string[];
  hasJacToml: boolean;
  jacTomlEntry: string | null;
}): ProjectType {
  const files = info.jacFiles;
  const hasServer = files.some((f) => f.includes(".sv.jac") || f.includes("server"));
  const hasClient = files.some((f) => f.includes(".cl.jac") || f.includes("client"));
  const entry = info.jacTomlEntry?.toLowerCase() ?? "";

  if (hasServer && hasClient) return "fullstack";
  if (hasServer && !hasClient) return "api";
  if (hasClient && !hasServer) return "client-only";
  if (files.length > 0 && entry.includes("main.jac")) return "library";
  if (files.length > 0) return "mixed";
  return "non-jac";
}

function parseNpmDeps(cwd: string): string[] {
  const tomlPath = join(cwd, "jac.toml");
  if (!existsSync(tomlPath)) return [];

  try {
    const content = readFileSync(tomlPath, "utf-8");
    // Simple TOML parsing for [dependencies.npm] section
    const inNpmDeps = content
      .split("\n")
      .reduce<{ inSection: boolean; deps: string[] }>(
        (acc, line) => {
          if (line.trim() === "[dependencies.npm]") {
            return { ...acc, inSection: true };
          }
          if (acc.inSection && line.trim().startsWith("[")) {
            return { ...acc, inSection: false };
          }
          if (acc.inSection) {
            const match = line.match(/^(\w[\w.-]*)\s*=/);
            if (match) acc.deps.push(match[1]!);
          }
          return acc;
        },
        { inSection: false, deps: [] },
      );
    return inNpmDeps.deps;
  } catch {
    return [];
  }
}

function parseJacToml(cwd: string): {
  name: string;
  description: string;
  entryPoint: string | null;
} {
  const tomlPath = join(cwd, "jac.toml");
  if (!existsSync(tomlPath))
    return { name: "", description: "", entryPoint: null };

  try {
    const content = readFileSync(tomlPath, "utf-8");
    let name = "";
    let description = "";
    let entryPoint: string | null = null;

    for (const line of content.split("\n")) {
      const nameMatch = line.match(/^name\s*=\s*"([^"]*)"/);
      if (nameMatch) name = nameMatch[1]!;

      const descMatch = line.match(/^description\s*=\s*"([^"]*)"/);
      if (descMatch) description = descMatch[1]!;

      const entryMatch = line.match(/^entry-point\s*=\s*"([^"]*)"/);
      if (entryMatch) entryPoint = entryMatch[1]!;
    }

    return { name, description, entryPoint };
  } catch {
    return { name: "", description: "", entryPoint: null };
  }
}

/**
 * Analyze a project directory and return structured info.
 */
export function analyzeProject(cwd: string): ProjectInfo {
  const resolved = resolve(cwd);
  const toml = parseJacToml(resolved);
  const jacFiles = scanFiles(resolved, [".jac"]);
  const pythonFiles = scanFiles(resolved, [".py"]);
  const npmDeps = parseNpmDeps(resolved);

  const jacVersion = runQuiet("jac --version 2>/dev/null || jaclang --version 2>/dev/null", resolved);
  const pythonVersion = runQuiet("python3 --version", resolved);

  const hasTests =
    jacFiles.some(
      (f) => f.includes("test") || f.includes("spec"),
    ) || pythonFiles.some((f) => f.includes("test"));

  const projectType = classifyProject({
    jacFiles,
    hasJacToml: existsSync(join(resolved, "jac.toml")),
    jacTomlEntry: toml.entryPoint,
  });

  return {
    projectName: toml.name || relative(resolve(resolved, ".."), resolved),
    description: toml.description,
    hasJacToml: existsSync(join(resolved, "jac.toml")),
    jacTomlEntry: toml.entryPoint,
    jacVersion,
    pythonVersion,
    jacFiles,
    pythonFiles,
    hasVenv:
      existsSync(join(resolved, ".venv")) ||
      existsSync(join(resolved, "venv")),
    hasGit: existsSync(join(resolved, ".git")),
    hasTests,
    hasReadme:
      existsSync(join(resolved, "README.md")) ||
      existsSync(join(resolved, "readme.md")),
    hasAgentsMd: existsSync(join(resolved, "AGENTS.md")),
    hasJackalConfig: existsSync(join(resolved, ".jackal")),
    npmDeps,
    projectType,
  };
}

/**
 * Generate an AGENTS.md template from project analysis.
 */
export function generateAgentsMd(info: ProjectInfo): string {
  const lines: string[] = [];

  lines.push(`# ${info.projectName || "Project"}`);
  lines.push("");

  if (info.description) {
    lines.push(info.description);
    lines.push("");
  }

  lines.push("## Project Type");
  lines.push("");
  lines.push(`**${info.projectType}** Jac project.`);
  lines.push("");

  // Stack
  lines.push("## Stack");
  lines.push("");
  if (info.jacVersion) lines.push(`- **Jac:** ${info.jacVersion}`);
  if (info.pythonVersion) lines.push(`- **Python:** ${info.pythonVersion}`);
  if (info.hasJacToml) lines.push("- **Config:** `jac.toml`");
  if (info.hasVenv) lines.push("- **Virtual env:** `.venv/`");
  if (info.npmDeps.length > 0) {
    lines.push(`- **NPM deps:** ${info.npmDeps.join(", ")}`);
  }
  lines.push("");

  // Structure
  lines.push("## Key Files");
  lines.push("");
  if (info.jacTomlEntry) {
    lines.push(`- **Entry point:** \`${info.jacTomlEntry}\``);
  }

  const serverFiles = info.jacFiles.filter((f) => f.includes(".sv.jac"));
  const clientFiles = info.jacFiles.filter((f) => f.includes(".cl.jac"));
  const walkerFiles = info.jacFiles.filter((f) => f.includes("walker"));
  const mainFiles = info.jacFiles.filter(
    (f) => f.endsWith("main.jac") || f.endsWith("app.jac"),
  );
  const testFiles = info.jacFiles.filter(
    (f) => f.includes("test") || f.includes("spec"),
  );

  if (mainFiles.length > 0) {
    lines.push(`- **Main:** ${mainFiles.map((f) => `\`${f}\``).join(", ")}`);
  }
  if (serverFiles.length > 0) {
    lines.push(
      `- **Server (${serverFiles.length}):** ${serverFiles.slice(0, 5).map((f) => `\`${f}\``).join(", ")}${serverFiles.length > 5 ? ` +${serverFiles.length - 5} more` : ""}`,
    );
  }
  if (clientFiles.length > 0) {
    lines.push(
      `- **Client (${clientFiles.length}):** ${clientFiles.slice(0, 5).map((f) => `\`${f}\``).join(", ")}${clientFiles.length > 5 ? ` +${clientFiles.length - 5} more` : ""}`,
    );
  }
  if (walkerFiles.length > 0) {
    lines.push(
      `- **Walkers:** ${walkerFiles.slice(0, 5).map((f) => `\`${f}\``).join(", ")}${walkerFiles.length > 5 ? ` +${walkerFiles.length - 5} more` : ""}`,
    );
  }
  if (testFiles.length > 0) {
    lines.push(
      `- **Tests:** ${testFiles.map((f) => `\`${f}\``).join(", ")}`,
    );
  }

  const otherJac = info.jacFiles.filter((f) => {
    return (
      !mainFiles.includes(f) &&
      !serverFiles.includes(f) &&
      !clientFiles.includes(f) &&
      !walkerFiles.includes(f) &&
      !testFiles.includes(f)
    );
  });
  if (otherJac.length > 0) {
    lines.push(
      `- **Other Jac (${otherJac.length}):** ${otherJac.slice(0, 8).map((f) => `\`${f}\``).join(", ")}${otherJac.length > 8 ? ` +${otherJac.length - 8} more` : ""}`,
    );
  }
  lines.push("");

  // Total counts
  lines.push("## File Counts");
  lines.push("");
  lines.push(`- \`.jac\` files: ${info.jacFiles.length}`);
  lines.push(`- \`.py\` files: ${info.pythonFiles.length}`);
  lines.push("");

  // Guidelines
  lines.push("## Development Guidelines");
  lines.push("");
  lines.push("- Run `jac check` after editing `.jac` files");
  if (info.hasTests) {
    lines.push("- Run `jac test` before committing");
  }
  lines.push("- Use `jac format` to keep code style consistent");
  if (info.projectType === "fullstack") {
    lines.push(
      "- Server code in `.sv.jac`, client code in `.cl.jac` — follow Jac fullstack conventions",
    );
  }
  if (info.hasGit) {
    lines.push("- Commit with clear messages; prefer small, focused changes");
  }
  lines.push("");

  // Jackal config
  if (!info.hasJackalConfig) {
    lines.push("## Jackal Configuration");
    lines.push("");
    lines.push("No `.jackal` config found. Create one with:");
    lines.push("```json");
    lines.push(JSON.stringify({
      autocheck: true,
      autoformat: true,
      maxFixAttempts: 3,
      autoCompact: { enabled: true, thresholdPercent: 80 },
      sessions: { autoSave: true, maxCount: 50, retentionDays: 30 },
    }, null, 2));
    lines.push("```");
    lines.push("");
  }

  return lines.join("\n");
}

/**
 * Run `/init` — analyze project and write/update AGENTS.md.
 */
export async function runProjectInit(
  cwd: string,
  options?: { force?: boolean; lean?: boolean },
): Promise<{ written: boolean; path: string; content: string }> {
  const info = analyzeProject(cwd);
  const agentsPath = join(resolve(cwd), "AGENTS.md");

  if (existsSync(agentsPath) && !options?.force) {
    // Append a note instead of overwriting
    const existing = readFileSync(agentsPath, "utf-8");
    if (existing.includes("<!-- jackal-init -->")) {
      return {
        written: false,
        path: agentsPath,
        content: "AGENTS.md already has a Jackal init section. Use --force to overwrite.",
      };
    }
    return {
      written: false,
      path: agentsPath,
      content: "AGENTS.md already exists. Use --force to overwrite.",
    };
  }

  const content = options?.lean
    ? generateAgentsMd(info).split("\n").slice(0, 30).join("\n")
    : generateAgentsMd(info);

  const finalContent = `<!-- jackal-init -->\n${content}`;

  writeFileSync(agentsPath, finalContent, "utf-8");

  return { written: true, path: agentsPath, content: finalContent };
}
