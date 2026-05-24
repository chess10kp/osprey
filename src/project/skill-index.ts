// Skill index — scans pi/skills/*/SKILL.md and builds a discoverable catalog.
//
// The agent reads the skill catalog in its system prompt footer and loads
// specific SKILL.md files on demand via the `read` tool when a task matches.

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { frontmatterString, parseFrontmatter } from "../orchestration/frontmatter.js";

export interface SkillEntry {
  name: string;
  description: string;
  /** Relative path from package root (e.g. "pi/skills/osp-skill/SKILL.md"). */
  relativePath: string;
  /** Absolute path to the SKILL.md file. */
  absolutePath: string;
  /** Keywords for matching (extracted from name + description). */
  keywords: string[];
}

function resolvePackageRoot(): string {
  if (process.env.JACKAL_AGENT_DIR) {
    return resolve(process.env.JACKAL_AGENT_DIR);
  }
  return resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
}

function extractKeywords(name: string, description: string): string[] {
  const text = `${name} ${description}`.toLowerCase();
  // Split on non-alphanumeric, deduplicate, filter short words
  const words = new Set(
    text
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length >= 3)
      .map((w) => w),
  );
  return [...words];
}

function scanSkillDir(skillsDir: string, packageRoot: string): SkillEntry[] {
  if (!existsSync(skillsDir)) return [];

  const entries: SkillEntry[] = [];

  let dirs: string[];
  try {
    dirs = readdirSync(skillsDir, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name)
      .sort();
  } catch {
    return [];
  }

  for (const dirName of dirs) {
    const skillFile = join(skillsDir, dirName, "SKILL.md");
    if (!existsSync(skillFile)) continue;

    try {
      const raw = readFileSync(skillFile, "utf-8");
      const { frontmatter, body } = parseFrontmatter(raw);
      const name = frontmatterString(frontmatter.name)?.trim() ?? dirName;
      const description =
        frontmatterString(frontmatter.description)?.trim() ??
        body.split("\n").find((l) => l.trim().length > 0)?.trim() ??
        "";

      entries.push({
        name,
        description,
        relativePath: `pi/skills/${dirName}/SKILL.md`,
        absolutePath: skillFile,
        keywords: extractKeywords(name, description),
      });
    } catch {
      // Skip invalid skill files
    }
  }

  return entries;
}

/**
 * Build the skill index from pi/skills/.
 * Returns entries sorted by name.
 */
export function buildSkillIndex(packageRoot?: string): SkillEntry[] {
  const root = packageRoot ?? resolvePackageRoot();
  const skillsDir = join(root, "pi", "skills");
  const entries = scanSkillDir(skillsDir, root);
  return entries.sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Build a compact skill catalog string for the system prompt footer.
 * The agent uses this to decide which SKILL.md to read on demand.
 */
export function formatSkillCatalog(entries: SkillEntry[]): string {
  if (entries.length === 0) return "";

  const lines = [
    `Available skills (${entries.length} — read with 'read' tool when task matches):`,
    "",
  ];

  for (const entry of entries) {
    // Truncate long descriptions to one line
    const desc =
      entry.description.length > 120
        ? `${entry.description.slice(0, 117)}...`
        : entry.description;
    lines.push(`- ${entry.name}: ${desc}`);
  }

  lines.push("");
  lines.push(
    "When a task matches a skill's description, read the SKILL.md file first for specialized instructions.",
  );

  return lines.join("\n");
}

/**
 * Find skills matching a query by keyword overlap.
 */
export function searchSkills(
  entries: SkillEntry[],
  query: string,
  limit = 5,
): SkillEntry[] {
  const queryWords = new Set(
    query
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length >= 3),
  );

  if (queryWords.size === 0) return entries.slice(0, limit);

  const scored = entries
    .map((entry) => {
      const overlap = entry.keywords.filter((k) => queryWords.has(k)).length;
      return { entry, score: overlap };
    })
    .filter((s) => s.score > 0)
    .sort((a, b) => b.score - a.score);

  return scored.slice(0, limit).map((s) => s.entry);
}

/**
 * Load the body of a skill file (frontmatter stripped).
 */
export function loadSkillBody(absolutePath: string): string | null {
  if (!existsSync(absolutePath)) return null;
  try {
    const raw = readFileSync(absolutePath, "utf-8");
    const { body } = parseFrontmatter(raw);
    return body.trim();
  } catch {
    return null;
  }
}

/**
 * Append skill catalog to the system prompt.
 */
export function appendSkillCatalogToPrompt(
  systemPrompt: string,
  packageRoot?: string,
): string {
  const entries = buildSkillIndex(packageRoot);
  if (entries.length === 0) return systemPrompt;

  const catalog = formatSkillCatalog(entries);
  return `${systemPrompt}\n\n---\n\n${catalog}`;
}
