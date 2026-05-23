import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Model, Api } from "@earendil-works/pi-ai";
import { frontmatterString, frontmatterStringList, parseFrontmatter } from "./frontmatter.js";
import { loadProjectConfig } from "./project-config.js";
import type { JackalModels } from "./auth.js";

export type SubagentSource = "package" | "project";

export interface SubagentDefinition {
  name: string;
  description: string;
  systemPrompt: string;
  tools?: string[];
  model?: string;
  source: SubagentSource;
  filePath: string;
}

/** Map common subagent tool names to Jackal runtime tools. */
export const SUBAGENT_TOOL_ALIASES: Record<string, string> = {
  read_file: "read",
  write_file: "write",
  edit_file: "edit",
  grep: "bash",
  find: "bash",
  ls: "bash",
  list_directory: "bash",
  search_file_contents: "bash",
  find_files: "bash",
};

const EXCLUDED_SUBAGENT_TOOLS = new Set(["agent", "subagent", "compact_context"]);

export function resolveJackalRoot(): string {
  if (process.env.JACKAL_AGENT_DIR) {
    return resolve(process.env.JACKAL_AGENT_DIR);
  }
  return resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
}

function listMarkdownFiles(dir: string, predicate: (name: string) => boolean): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];

  function walk(current: string): void {
    let entries;
    try {
      entries = readdirSync(current, { withFileTypes: true }).sort((a, b) =>
        a.name.localeCompare(b.name),
      );
    } catch {
      return;
    }

    for (const entry of entries) {
      const filePath = join(current, entry.name);
      if (entry.isDirectory()) {
        walk(filePath);
        continue;
      }
      if (!entry.isFile()) continue;
      if (!predicate(entry.name)) continue;
      out.push(filePath);
    }
  }

  walk(dir);
  return out;
}

function loadAgentFile(filePath: string, source: SubagentSource): SubagentDefinition | null {
  let content: string;
  try {
    content = readFileSync(filePath, "utf-8");
  } catch {
    return null;
  }

  const { frontmatter, body } = parseFrontmatter(content);
  const name = frontmatterString(frontmatter.name)?.trim();
  const description = frontmatterString(frontmatter.description)?.trim();
  if (!name || !description) return null;

  const rawTools = frontmatterStringList(frontmatter.tools);
  const tools = rawTools.length > 0 ? rawTools : undefined;

  return {
    name,
    description,
    systemPrompt: body.trim(),
    tools,
    model: frontmatterString(frontmatter.model),
    source,
    filePath,
  };
}

function loadAgentsFromDir(dir: string, source: SubagentSource): SubagentDefinition[] {
  return listMarkdownFiles(dir, (name) => name.endsWith(".md") && !name.endsWith(".chain.md"))
    .map((filePath) => loadAgentFile(filePath, source))
    .filter((agent): agent is SubagentDefinition => agent !== null);
}

function loadSettingsModelOverrides(): Record<string, string> {
  const settingsPath = join(resolveJackalRoot(), "settings.json");
  if (!existsSync(settingsPath)) return {};

  try {
    const parsed = JSON.parse(readFileSync(settingsPath, "utf-8")) as {
      subagents?: { agentOverrides?: Record<string, { model?: string }> };
    };
    const overrides = parsed.subagents?.agentOverrides ?? {};
    const out: Record<string, string> = {};
    for (const [name, value] of Object.entries(overrides)) {
      if (value?.model) out[name] = value.model;
    }
    return out;
  } catch {
    return {};
  }
}

function loadProjectModelOverrides(cwd: string): Record<string, string> {
  const cfg = loadProjectConfig(cwd);
  const sub = cfg.subagents;
  if (!sub || typeof sub !== "object") return {};

  const out: Record<string, string> = {};
  if (typeof sub.model === "string" && sub.model.trim()) {
    out.__default__ = sub.model.trim();
  }

  for (const [key, value] of Object.entries(sub)) {
    if (key === "model" || key === "enabled") continue;
    if (typeof value === "string" && value.trim()) {
      out[key] = value.trim();
    } else if (value && typeof value === "object" && typeof value.model === "string") {
      out[key] = value.model.trim();
    }
  }
  return out;
}

export function discoverSubagentDirs(cwd: string): {
  packageDir: string;
  projectDir: string;
} {
  const root = resolveJackalRoot();
  return {
    packageDir: join(root, ".pi", "agents"),
    projectDir: join(resolve(cwd), "subagents"),
  };
}

/** Load subagents: project `subagents/` overrides package `.pi/agents/`. */
export function loadSubagents(cwd: string): Map<string, SubagentDefinition> {
  const { packageDir, projectDir } = discoverSubagentDirs(cwd);
  const merged = new Map<string, SubagentDefinition>();

  for (const agent of loadAgentsFromDir(packageDir, "package")) {
    merged.set(agent.name, agent);
  }
  for (const agent of loadAgentsFromDir(projectDir, "project")) {
    merged.set(agent.name, agent);
  }

  return merged;
}

export function listSubagents(cwd: string): SubagentDefinition[] {
  return [...loadSubagents(cwd).values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function getSubagent(cwd: string, name: string): SubagentDefinition | undefined {
  return loadSubagents(cwd).get(name.trim());
}

export function resolveSubagentModel(
  agent: SubagentDefinition,
  parentModel: Model<Api>,
  models: JackalModels,
  cwd: string,
  stepModel?: string,
): Model<Api> {
  const settingsOverrides = loadSettingsModelOverrides();
  const projectOverrides = loadProjectModelOverrides(cwd);

  const candidates = [
    stepModel,
    agent.model,
    projectOverrides[agent.name],
    settingsOverrides[agent.name],
    projectOverrides.__default__,
  ].filter((value): value is string => Boolean(value && value.trim() && value !== "inherit"));

  for (const spec of candidates) {
    const resolved = resolveModelSpec(spec, parentModel, models);
    if (resolved) return resolved;
  }

  return parentModel;
}

function resolveModelSpec(
  spec: string,
  parentModel: Model<Api>,
  models: JackalModels,
): Model<Api> | undefined {
  const trimmed = spec.trim();
  if (!trimmed || trimmed === "inherit") return undefined;

  if (trimmed.includes("/")) {
    const slash = trimmed.indexOf("/");
    const provider = trimmed.slice(0, slash);
    const id = trimmed.slice(slash + 1);
    return models.find(provider, id) ?? models.getAvailable().find((m) => m.id === id);
  }

  return (
    models.find(parentModel.provider, trimmed) ??
    models.getAvailable().find((m) => m.id === trimmed) ??
    models.getAll().find((m) => m.id === trimmed)
  );
}

export function normalizeAllowedToolNames(tools?: string[]): Set<string> | null {
  if (!tools || tools.length === 0) return null;

  const allowed = new Set<string>();
  for (const raw of tools) {
    const name = raw.trim();
    if (!name) continue;
    if (name.startsWith("mcp:")) {
      allowed.add(name.slice(4));
      continue;
    }
    const mapped = SUBAGENT_TOOL_ALIASES[name] ?? name;
    allowed.add(mapped);
  }
  return allowed;
}

export function filterToolsForSubagent<T extends { name: string }>(
  allTools: T[],
  allowedNames: Set<string> | null,
): T[] {
  const filtered = allTools.filter((tool) => {
    if (EXCLUDED_SUBAGENT_TOOLS.has(tool.name)) return false;
    if (!allowedNames) return true;
    return allowedNames.has(tool.name);
  });

  if (allowedNames?.has("bash") && !filtered.some((tool) => tool.name === "bash")) {
    const bash = allTools.find((tool) => tool.name === "bash");
    if (bash) filtered.push(bash);
  }

  return filtered.length > 0 ? filtered : allTools.filter((tool) => !EXCLUDED_SUBAGENT_TOOLS.has(tool.name));
}

export function formatSubagentCatalog(cwd: string): string {
  const agents = listSubagents(cwd);
  if (agents.length === 0) return "No subagents found.";

  const lines = ["Available subagents:", ""];
  for (const agent of agents) {
    const toolCount = agent.tools?.length ?? "all";
    lines.push(`- ${agent.name} (${agent.source}) — ${agent.description}`);
    lines.push(`  tools: ${String(toolCount)}  model: ${agent.model ?? "inherit"}`);
  }
  return lines.join("\n");
}

export function isExistingDir(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}
