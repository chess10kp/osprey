// Jackal Jac differentiator workflows — delegates prompt building to lib/jac/jac/workflows.

import type { JackalAgentSession } from "../session/agent-session.js";
import {
  bridgeBuildConvertPythonPrompt,
  bridgeBuildDiagramToModelPrompt,
  bridgeBuildExplainPrompt,
  bridgeBuildIdiomReviewPrompt,
  bridgeBuildOspPrompt,
  bridgeLoadSkillContent,
  bridgeRenderPromptTemplate,
} from "./jac-bridge.js";

/** Read a skill's SKILL.md body (YAML frontmatter stripped). */
export function loadSkillContent(skillDirName: string, packageRoot?: string): string {
  return bridgeLoadSkillContent(skillDirName, packageRoot);
}

/** Load a prompt template from pi/prompts/ and substitute `{{key}}` placeholders. */
export function renderPromptTemplate(
  name: string,
  vars: Record<string, string>,
  packageRoot?: string,
): string {
  return bridgeRenderPromptTemplate(name, vars, packageRoot);
}

export function buildOspPrompt(description: string, packageRoot?: string): string {
  return bridgeBuildOspPrompt(description, packageRoot);
}

export function buildConvertPythonPrompt(pythonPath: string, packageRoot?: string): string {
  return bridgeBuildConvertPythonPrompt(pythonPath, packageRoot);
}

export function buildIdiomReviewPrompt(paths: string[], packageRoot?: string): string {
  return bridgeBuildIdiomReviewPrompt(paths, packageRoot);
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

// ── Explain workflows ──────────────────────────────────────────────

export type ExplainMode = "file" | "walker" | "error" | "graph";

/** Build a prompt for /jac explain <mode>. */
export function buildExplainPrompt(
  mode: ExplainMode,
  args: string,
  packageRoot?: string,
): string {
  return bridgeBuildExplainPrompt(mode, args, packageRoot);
}

/** Run /jac explain <mode> <code_or_error>. */
export async function runExplain(
  session: JackalAgentSession,
  mode: ExplainMode,
  args: string,
): Promise<void> {
  const prompt = buildExplainPrompt(mode, args);
  await session.sendUserMessage(prompt);
}

/** Run /init — analyze project and generate AGENTS.md. */
export async function runInit(
  session: JackalAgentSession,
  cwd: string,
  options?: { force?: boolean; lean?: boolean },
): Promise<string> {
  const { runProjectInit } = await import("../project/project-init.js");
  const result = await runProjectInit(cwd, options);
  if (result.written) {
    return `Generated ${result.path}`;
  }
  return result.content;
}

export function buildDiagramToModelPrompt(
  source: string,
  content: string,
  packageRoot?: string,
): string {
  return bridgeBuildDiagramToModelPrompt(source, content, packageRoot);
}

/** Run /jac diagram-to-model — multimodal/text diagram → OSP Jac model. */
export async function runDiagramToModel(
  session: JackalAgentSession,
  source: string,
  content = "",
): Promise<void> {
  const prompt = buildDiagramToModelPrompt(source, content);
  await session.sendUserMessage(prompt);
}
