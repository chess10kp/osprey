// Jackal Jac differentiator workflows — OSP, Python→Jac, idiom review.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { JackalAgentSession } from "./agent-session.js";

function resolvePackageRoot(): string {
  const fromModule = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
  if (existsSync(join(fromModule, "pi", "skills"))) {
    return fromModule;
  }
  return fromModule;
}

/** Read a skill's SKILL.md body (YAML frontmatter stripped). */
export function loadSkillContent(skillDirName: string, packageRoot = resolvePackageRoot()): string {
  const path = join(packageRoot, "pi", "skills", skillDirName, "SKILL.md");
  if (!existsSync(path)) {
    return "";
  }
  try {
    const raw = readFileSync(path, "utf-8");
    const stripped = raw.replace(/^---[\s\S]*?---\s*/m, "").trim();
    return stripped;
  } catch {
    return "";
  }
}

/** Load a prompt template from pi/prompts/ and substitute `{{key}}` placeholders. */
export function renderPromptTemplate(
  name: string,
  vars: Record<string, string>,
  packageRoot = resolvePackageRoot(),
): string {
  const path = join(packageRoot, "pi", "prompts", `${name}.md`);
  if (!existsSync(path)) {
    throw new Error(`Prompt template not found: pi/prompts/${name}.md`);
  }
  let text = readFileSync(path, "utf-8");
  for (const [key, value] of Object.entries(vars)) {
    text = text.split(`{{${key}}}`).join(value);
  }
  return text.trim();
}

export function buildOspPrompt(description: string): string {
  const ospSkill = loadSkillContent("osp-skill");
  return renderPromptTemplate("osp", {
    description: description.trim(),
    osp_skill: ospSkill || "(osp-skill unavailable — use Jac MCP list_examples/get_example/search_docs)",
  });
}

export function buildConvertPythonPrompt(pythonPath: string): string {
  return renderPromptTemplate("convert-python", {
    path: pythonPath.trim(),
  });
}

export function buildIdiomReviewPrompt(paths: string[]): string {
  const normalized = paths.map((p) => p.trim()).filter(Boolean);
  const fileList =
    normalized.length > 0
      ? normalized.map((p) => `- \`${p}\``).join("\n")
      : "- (scan all `.jac` files in the project)";
  return renderPromptTemplate("review-idioms", {
    paths: normalized.join(", ") || "(project-wide)",
    file_list: fileList,
  });
}

/** Run the OSP graph-modeling workflow (/osp). */
export async function runOspWorkflow(
  session: JackalAgentSession,
  prompt: string,
): Promise<void> {
  const desc = prompt.trim();
  if (!desc) {
    throw new Error("OSP workflow requires a description");
  }
  await session.sendUserMessage(buildOspPrompt(desc));
}

/** Run Python → Jac conversion workflow (/jac convert-python). */
export async function runConvertPython(
  session: JackalAgentSession,
  path: string,
): Promise<void> {
  const target = path.trim();
  if (!target) {
    throw new Error("convert-python workflow requires a Python file path");
  }
  await session.sendUserMessage(buildConvertPythonPrompt(target));
}

/** Run Jac idiom review workflow (/jac review-idioms). */
export async function runIdiomReview(
  session: JackalAgentSession,
  paths: string[],
): Promise<void> {
  await session.sendUserMessage(buildIdiomReviewPrompt(paths));
}
