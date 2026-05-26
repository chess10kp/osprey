import { bridgeFormatSkillCommandCatalog } from "../jac/jac-bridge.js";
import { loadJackalSkills } from "../project/skills.js";

export function formatSkillCommandCatalog(cwd: string): string {
  const { skills } = loadJackalSkills({ cwd });
  return bridgeFormatSkillCommandCatalog(
    skills.map((skill) => ({
      name: skill.name,
      description: skill.description,
      source: skill.source,
    })),
  );
}
