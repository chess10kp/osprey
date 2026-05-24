// Agent Skills loader — ported from reference/pi/packages/coding-agent/src/core/skills.ts
// with Jackal-specific locations (pi/skills, ~/.jackal/skills, .jackal/skills).

import {
  existsSync,
  readdirSync,
  readFileSync,
  realpathSync,
  statSync,
} from "node:fs";
import ignore from "ignore";
import { homedir } from "node:os";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from "node:path";
import { fileURLToPath } from "node:url";
import {
  frontmatterString,
  parseFrontmatter,
} from "../orchestration/frontmatter.js";

const MAX_NAME_LENGTH = 64;
const MAX_DESCRIPTION_LENGTH = 1024;
const IGNORE_FILE_NAMES = [".gitignore", ".ignore", ".fdignore"];

type IgnoreMatcher = ReturnType<typeof ignore>;

export type SkillSource = "builtin" | "user" | "project" | "path";

export interface Skill {
  name: string;
  description: string;
  filePath: string;
  baseDir: string;
  source: SkillSource;
  disableModelInvocation: boolean;
}

export interface SkillDiagnostic {
  type: "warning" | "collision";
  message: string;
  path: string;
  collision?: {
    name: string;
    winnerPath: string;
    loserPath: string;
  };
}

export interface LoadSkillsResult {
  skills: Skill[];
  diagnostics: SkillDiagnostic[];
}

export interface LoadSkillsFromDirOptions {
  dir: string;
  source: SkillSource;
}

export interface LoadJackalSkillsOptions {
  cwd?: string;
  packageRoot?: string;
  /** Global skills root (default ~/.jackal). */
  agentDir?: string;
  skillPaths?: string[];
  includeDefaults?: boolean;
}

function resolvePackageRoot(): string {
  if (process.env.JACKAL_AGENT_DIR) {
    return resolve(process.env.JACKAL_AGENT_DIR);
  }
  return resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
}

function toPosixPath(p: string): string {
  return p.split(sep).join("/");
}

function canonicalizePath(filePath: string): string {
  try {
    return realpathSync(filePath);
  } catch {
    return resolve(filePath);
  }
}

function prefixIgnorePattern(line: string, prefix: string): string | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  if (trimmed.startsWith("#") && !trimmed.startsWith("\\#")) return null;

  let pattern = line;
  let negated = false;

  if (pattern.startsWith("!")) {
    negated = true;
    pattern = pattern.slice(1);
  } else if (pattern.startsWith("\\!")) {
    pattern = pattern.slice(1);
  }

  if (pattern.startsWith("/")) {
    pattern = pattern.slice(1);
  }

  const prefixed = prefix ? `${prefix}${pattern}` : pattern;
  return negated ? `!${prefixed}` : prefixed;
}

function addIgnoreRules(ig: IgnoreMatcher, dir: string, rootDir: string): void {
  const relativeDir = relative(rootDir, dir);
  const prefix = relativeDir ? `${toPosixPath(relativeDir)}/` : "";

  for (const filename of IGNORE_FILE_NAMES) {
    const ignorePath = join(dir, filename);
    if (!existsSync(ignorePath)) continue;
    try {
      const content = readFileSync(ignorePath, "utf-8");
      const patterns = content
        .split(/\r?\n/)
        .map((line) => prefixIgnorePattern(line, prefix))
        .filter((line): line is string => Boolean(line));
      if (patterns.length > 0) {
        ig.add(patterns);
      }
    } catch {
      // ignore unreadable ignore files
    }
  }
}

function validateName(name: string): string[] {
  const errors: string[] = [];
  if (name.length > MAX_NAME_LENGTH) {
    errors.push(`name exceeds ${MAX_NAME_LENGTH} characters (${name.length})`);
  }
  if (!/^[a-z0-9-]+$/.test(name)) {
    errors.push("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)");
  }
  if (name.startsWith("-") || name.endsWith("-")) {
    errors.push("name must not start or end with a hyphen");
  }
  if (name.includes("--")) {
    errors.push("name must not contain consecutive hyphens");
  }
  return errors;
}

function validateDescription(description: string | undefined): string[] {
  const errors: string[] = [];
  if (!description || description.trim() === "") {
    errors.push("description is required");
  } else if (description.length > MAX_DESCRIPTION_LENGTH) {
    errors.push(
      `description exceeds ${MAX_DESCRIPTION_LENGTH} characters (${description.length})`,
    );
  }
  return errors;
}

function findProjectSkillsDir(cwd: string): string | null {
  let cur = resolve(cwd);
  while (true) {
    const dir = join(cur, ".jackal", "skills");
    if (existsSync(dir)) return dir;
    const parent = resolve(cur, "..");
    if (parent === cur) return null;
    cur = parent;
  }
}

function normalizePath(input: string): string {
  const trimmed = input.trim();
  if (trimmed === "~") return homedir();
  if (trimmed.startsWith("~/")) return join(homedir(), trimmed.slice(2));
  if (trimmed.startsWith("~")) return join(homedir(), trimmed.slice(1));
  return trimmed;
}

function resolveSkillPath(p: string, cwd: string): string {
  const normalized = normalizePath(p);
  return isAbsolute(normalized) ? normalized : resolve(cwd, normalized);
}

function loadSkillFromFile(
  filePath: string,
  source: SkillSource,
): { skill: Skill | null; diagnostics: SkillDiagnostic[] } {
  const diagnostics: SkillDiagnostic[] = [];

  try {
    const rawContent = readFileSync(filePath, "utf-8");
    const { frontmatter } = parseFrontmatter(rawContent);
    const skillDir = dirname(filePath);
    const parentDirName = basename(skillDir);
    const description = frontmatterString(frontmatter.description);
    const disableModelInvocation =
      frontmatterString(frontmatter["disable-model-invocation"])?.toLowerCase() === "true";

    for (const error of validateDescription(description)) {
      diagnostics.push({ type: "warning", message: error, path: filePath });
    }

    const name = frontmatterString(frontmatter.name)?.trim() || parentDirName;

    for (const error of validateName(name)) {
      diagnostics.push({ type: "warning", message: error, path: filePath });
    }

    if (!description?.trim()) {
      return { skill: null, diagnostics };
    }

    return {
      skill: {
        name,
        description: description.trim(),
        filePath,
        baseDir: skillDir,
        source,
        disableModelInvocation,
      },
      diagnostics,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : "failed to parse skill file";
    diagnostics.push({ type: "warning", message, path: filePath });
    return { skill: null, diagnostics };
  }
}

function loadSkillsFromDirInternal(
  dir: string,
  source: SkillSource,
  includeRootFiles: boolean,
  ignoreMatcher?: IgnoreMatcher,
  rootDir?: string,
): LoadSkillsResult {
  const skills: Skill[] = [];
  const diagnostics: SkillDiagnostic[] = [];

  if (!existsSync(dir)) {
    return { skills, diagnostics };
  }

  const root = rootDir ?? dir;
  const ig = ignoreMatcher ?? ignore();
  addIgnoreRules(ig, dir, root);

  try {
    const entries = readdirSync(dir, { withFileTypes: true });

    for (const entry of entries) {
      if (entry.name !== "SKILL.md") continue;

      const fullPath = join(dir, entry.name);
      let isFile = entry.isFile();
      if (entry.isSymbolicLink()) {
        try {
          isFile = statSync(fullPath).isFile();
        } catch {
          continue;
        }
      }

      const relPath = toPosixPath(relative(root, fullPath));
      if (!isFile || ig.ignores(relPath)) continue;

      const result = loadSkillFromFile(fullPath, source);
      if (result.skill) skills.push(result.skill);
      diagnostics.push(...result.diagnostics);
      return { skills, diagnostics };
    }

    for (const entry of entries) {
      if (entry.name.startsWith(".") || entry.name === "node_modules") continue;

      const fullPath = join(dir, entry.name);
      let isDirectory = entry.isDirectory();
      let isFile = entry.isFile();
      if (entry.isSymbolicLink()) {
        try {
          const stats = statSync(fullPath);
          isDirectory = stats.isDirectory();
          isFile = stats.isFile();
        } catch {
          continue;
        }
      }

      const relPath = toPosixPath(relative(root, fullPath));
      const ignorePath = isDirectory ? `${relPath}/` : relPath;
      if (ig.ignores(ignorePath)) continue;

      if (isDirectory) {
        const subResult = loadSkillsFromDirInternal(fullPath, source, false, ig, root);
        skills.push(...subResult.skills);
        diagnostics.push(...subResult.diagnostics);
        continue;
      }

      if (!isFile || !includeRootFiles || !entry.name.endsWith(".md")) continue;

      const result = loadSkillFromFile(fullPath, source);
      if (result.skill) skills.push(result.skill);
      diagnostics.push(...result.diagnostics);
    }
  } catch {
    // unreadable directory
  }

  return { skills, diagnostics };
}

export function loadSkillsFromDir(options: LoadSkillsFromDirOptions): LoadSkillsResult {
  return loadSkillsFromDirInternal(options.dir, options.source, true);
}

export function formatSkillsForPrompt(skills: Skill[]): string {
  const visibleSkills = skills.filter((s) => !s.disableModelInvocation);
  if (visibleSkills.length === 0) return "";

  const lines = [
    "\n\nThe following skills provide specialized instructions for specific tasks.",
    "Use the read tool to load a skill's file when the task matches its description.",
    "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
    "",
    "<available_skills>",
  ];

  for (const skill of visibleSkills) {
    lines.push("  <skill>");
    lines.push(`    <name>${escapeXml(skill.name)}</name>`);
    lines.push(`    <description>${escapeXml(skill.description)}</description>`);
    lines.push(`    <location>${escapeXml(skill.filePath)}</location>`);
    lines.push("  </skill>");
  }

  lines.push("</available_skills>");
  return lines.join("\n");
}

function escapeXml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * Load skills from Jackal built-in, user, project, and explicit paths.
 * Later sources override earlier ones on name collision (project > user > builtin).
 */
export function loadJackalSkills(options: LoadJackalSkillsOptions = {}): LoadSkillsResult {
  const cwd = options.cwd ?? process.cwd();
  const packageRoot = options.packageRoot ?? resolvePackageRoot();
  const agentDir = options.agentDir ?? join(homedir(), ".jackal");
  const skillPaths = options.skillPaths ?? [];
  const includeDefaults = options.includeDefaults ?? true;

  const skillMap = new Map<string, Skill>();
  const realPathSet = new Set<string>();
  const allDiagnostics: SkillDiagnostic[] = [];
  const collisionDiagnostics: SkillDiagnostic[] = [];

  function addSkills(result: LoadSkillsResult): void {
    allDiagnostics.push(...result.diagnostics);
    for (const skill of result.skills) {
      const realPath = canonicalizePath(skill.filePath);
      if (realPathSet.has(realPath)) continue;
      realPathSet.add(realPath);

      const existing = skillMap.get(skill.name);
      if (existing) {
        collisionDiagnostics.push({
          type: "collision",
          message: `name "${skill.name}" collision`,
          path: skill.filePath,
          collision: {
            name: skill.name,
            winnerPath: skill.filePath,
            loserPath: existing.filePath,
          },
        });
      }
      skillMap.set(skill.name, skill);
    }
  }

  if (includeDefaults) {
    addSkills(loadSkillsFromDirInternal(join(packageRoot, "pi", "skills"), "builtin", true));
    addSkills(loadSkillsFromDirInternal(join(agentDir, "skills"), "user", true));
    const projectDir = findProjectSkillsDir(cwd);
    if (projectDir) {
      addSkills(loadSkillsFromDirInternal(projectDir, "project", true));
    }
  }

  const userSkillsDir = join(agentDir, "skills");
  const projectSkillsDir = findProjectSkillsDir(cwd);

  const isUnderPath = (target: string, root: string | null): boolean => {
    if (!root) return false;
    const normalizedRoot = resolve(root);
    if (target === normalizedRoot) return true;
    const prefix = normalizedRoot.endsWith(sep) ? normalizedRoot : `${normalizedRoot}${sep}`;
    return target.startsWith(prefix);
  };

  const getSource = (resolvedPath: string): SkillSource => {
    if (isUnderPath(resolvedPath, userSkillsDir)) return "user";
    if (isUnderPath(resolvedPath, projectSkillsDir)) return "project";
    return "path";
  };

  for (const rawPath of skillPaths) {
    const resolvedPath = resolveSkillPath(rawPath, cwd);
    if (!existsSync(resolvedPath)) {
      allDiagnostics.push({
        type: "warning",
        message: "skill path does not exist",
        path: resolvedPath,
      });
      continue;
    }

    try {
      const stats = statSync(resolvedPath);
      const source = getSource(resolvedPath);
      if (stats.isDirectory()) {
        addSkills(loadSkillsFromDirInternal(resolvedPath, source, true));
      } else if (stats.isFile() && resolvedPath.endsWith(".md")) {
        const result = loadSkillFromFile(resolvedPath, source);
        if (result.skill) {
          addSkills({ skills: [result.skill], diagnostics: result.diagnostics });
        } else {
          allDiagnostics.push(...result.diagnostics);
        }
      } else {
        allDiagnostics.push({
          type: "warning",
          message: "skill path is not a markdown file",
          path: resolvedPath,
        });
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "failed to read skill path";
      allDiagnostics.push({ type: "warning", message, path: resolvedPath });
    }
  }

  return {
    skills: [...skillMap.values()].sort((a, b) => a.name.localeCompare(b.name)),
    diagnostics: [...allDiagnostics, ...collisionDiagnostics],
  };
}

/** Expand `/skill:name` commands to full skill content (Pi agent-session behavior). */
export function expandSkillCommand(text: string, skills: Skill[]): string {
  if (!text.startsWith("/skill:")) return text;

  const spaceIndex = text.indexOf(" ");
  const skillName = spaceIndex === -1 ? text.slice(7) : text.slice(7, spaceIndex);
  const args = spaceIndex === -1 ? "" : text.slice(spaceIndex + 1).trim();

  const skill = skills.find((s) => s.name === skillName);
  if (!skill) return text;

  try {
    const content = readFileSync(skill.filePath, "utf-8");
    const { body } = parseFrontmatter(content);
    const skillBlock = `<skill name="${skill.name}" location="${skill.filePath}">\nReferences are relative to ${skill.baseDir}.\n\n${body.trim()}\n</skill>`;
    return args ? `${skillBlock}\n\n${args}` : skillBlock;
  } catch {
    return text;
  }
}

export function appendSkillsToPrompt(systemPrompt: string, skills: Skill[]): string {
  const catalog = formatSkillsForPrompt(skills);
  return catalog ? systemPrompt + catalog : systemPrompt;
}

/** Load a built-in skill body by directory name (e.g. osp-skill). */
export function loadSkillByDir(dirName: string, packageRoot = resolvePackageRoot()): string {
  const filePath = join(packageRoot, "pi", "skills", dirName, "SKILL.md");
  if (!existsSync(filePath)) return "";
  try {
    const { body } = parseFrontmatter(readFileSync(filePath, "utf-8"));
    return body.trim();
  } catch {
    return "";
  }
}

/** Absolute paths the read tool may access outside cwd (skill files + assets). */
export function skillReadAllowlist(skills: Skill[]): {
  files: Set<string>;
  roots: string[];
} {
  const files = new Set<string>();
  const roots: string[] = [];
  for (const skill of skills) {
    files.add(resolve(skill.filePath));
    roots.push(resolve(skill.baseDir) + sep);
  }
  return { files, roots };
}
