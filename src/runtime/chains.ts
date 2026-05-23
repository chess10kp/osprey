import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { frontmatterString, parseFrontmatter } from "./frontmatter.js";
import { resolveJackalRoot, isExistingDir } from "./subagents.js";
import { readdirSync } from "node:fs";

export type ChainSource = "package" | "project";

export interface ChainStep {
  agent: string;
  task: string;
  output?: string;
  reads?: string[];
  model?: string;
}

export interface ChainDefinition {
  name: string;
  description: string;
  steps: ChainStep[];
  source: ChainSource;
  filePath: string;
}

function listChainFiles(dir: string): string[] {
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
      if (entry.isFile() && entry.name.endsWith(".chain.md")) {
        out.push(filePath);
      }
    }
  }

  walk(dir);
  return out;
}

function parseStepBody(agent: string, sectionBody: string): ChainStep {
  const lines = sectionBody.split("\n");
  const blankIndex = lines.findIndex((line) => line.trim() === "");
  const configLines = blankIndex === -1 ? lines : lines.slice(0, blankIndex);
  const task = (blankIndex === -1 ? "" : lines.slice(blankIndex + 1).join("\n")).trim();

  const step: ChainStep = { agent, task };

  for (const line of configLines) {
    const match = line.match(/^([\w-]+):\s*(.*)$/i);
    if (!match) continue;
    const key = match[1]!.trim().toLowerCase();
    const rawValue = match[2]!.trim();

    if (key === "output" && rawValue) {
      step.output = rawValue;
      continue;
    }
    if (key === "reads" && rawValue) {
      step.reads = rawValue
        .split(",")
        .map((part) => part.trim())
        .filter(Boolean);
      continue;
    }
    if (key === "model" && rawValue) {
      step.model = rawValue;
    }
  }

  return step;
}

export function parseChainMarkdown(content: string, source: ChainSource, filePath: string): ChainDefinition {
  const { frontmatter, body } = parseFrontmatter(content);
  const name = frontmatterString(frontmatter.name)?.trim();
  const description = frontmatterString(frontmatter.description)?.trim();
  if (!name || !description) {
    throw new Error(`Chain frontmatter must include name and description (${filePath})`);
  }

  const matches = [...body.matchAll(/^##\s+(.+)[^\S\n]*$/gm)];
  const steps: ChainStep[] = [];

  for (let i = 0; i < matches.length; i++) {
    const match = matches[i]!;
    const agent = match[1]!.trim();
    const lineEndOffset = body[match.index! + match[0].length] === "\n" ? 1 : 0;
    const sectionStart = match.index! + match[0].length + lineEndOffset;
    const sectionEnd = i + 1 < matches.length ? matches[i + 1]!.index! : body.length;
    const sectionBody = body.slice(sectionStart, sectionEnd).trimEnd();
    steps.push(parseStepBody(agent, sectionBody));
  }

  if (steps.length === 0) {
    throw new Error(`Chain '${name}' has no ## steps (${filePath})`);
  }

  return { name, description, steps, source, filePath };
}

function loadChainsFromDir(dir: string, source: ChainSource): ChainDefinition[] {
  const chains: ChainDefinition[] = [];
  for (const filePath of listChainFiles(dir)) {
    try {
      const content = readFileSync(filePath, "utf-8");
      chains.push(parseChainMarkdown(content, source, filePath));
    } catch {
      /* skip invalid chain files */
    }
  }
  return chains;
}

export function discoverChainDirs(cwd: string): { packageDir: string; projectDir: string } {
  const root = resolveJackalRoot();
  return {
    packageDir: join(root, "chains"),
    projectDir: join(resolve(cwd), "chains"),
  };
}

export function loadChains(cwd: string): Map<string, ChainDefinition> {
  const { packageDir, projectDir } = discoverChainDirs(cwd);
  const merged = new Map<string, ChainDefinition>();

  for (const chain of loadChainsFromDir(packageDir, "package")) {
    merged.set(chain.name, chain);
  }
  for (const chain of loadChainsFromDir(projectDir, "project")) {
    merged.set(chain.name, chain);
  }

  return merged;
}

export function listChains(cwd: string): ChainDefinition[] {
  return [...loadChains(cwd).values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function getChain(cwd: string, name: string): ChainDefinition | undefined {
  return loadChains(cwd).get(name.trim());
}

export function formatChainCatalog(cwd: string): string {
  const chains = listChains(cwd);
  if (chains.length === 0) return "No chains found.";

  const lines = ["Available chains:", ""];
  for (const chain of chains) {
    const agents = chain.steps.map((step) => step.agent).join(" → ");
    lines.push(`- ${chain.name} (${chain.source}) — ${chain.description}`);
    lines.push(`  steps: ${agents}`);
  }
  return lines.join("\n");
}

export function chainDirsExist(cwd: string): boolean {
  const { packageDir, projectDir } = discoverChainDirs(cwd);
  return isExistingDir(packageDir) || isExistingDir(projectDir);
}
