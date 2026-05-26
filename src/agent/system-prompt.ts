import { bridgeLoadSystemPromptBase } from "../jac/jac-bridge.js";
import { appendSkillsToPrompt, loadJackalSkills } from "../project/skills.js";

export function loadJackalSystemPrompt(cwd: string, explicit?: string): string {
  const base = bridgeLoadSystemPromptBase(cwd, explicit);
  const { skills } = loadJackalSkills({ cwd });
  return appendSkillsToPrompt(base, skills);
}
