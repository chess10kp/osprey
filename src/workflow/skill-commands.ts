import { loadJackalSkills } from "../project/skills.js";

export function formatSkillCommandCatalog(cwd: string): string {
  const { skills } = loadJackalSkills({ cwd });
  if (skills.length === 0) {
    return [
      "No skills found.",
      "",
      "Built-in skills ship with Jackal under pi/skills/.",
      "Add project skills in .jackal/skills/<name>/SKILL.md.",
      "Add user skills in ~/.jackal/skills/<name>/SKILL.md.",
    ].join("\n");
  }

  const lines = [`Skills (${skills.length}):`, ""];
  for (const skill of skills) {
    const tag =
      skill.source === "project"
        ? " [project]"
        : skill.source === "user"
          ? " [user]"
          : skill.source === "builtin"
            ? " [built-in]"
            : "";
    lines.push(`- /skill:${skill.name}${tag} — ${skill.description}`);
  }
  lines.push("");
  lines.push("Use /skill:<name> to load a skill, or read the absolute path from the system prompt catalog.");
  return lines.join("\n");
}
