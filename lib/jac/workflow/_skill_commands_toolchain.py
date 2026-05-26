"""Skill command catalog formatting."""

from __future__ import annotations


def format_skill_command_catalog(skills: list[dict]) -> str:
    if not skills:
        return "\n".join(
            [
                "No skills found.",
                "",
                "Built-in skills ship with Jackal under pi/skills/.",
                "Add project skills in .jackal/skills/<name>/SKILL.md.",
                "Add user skills in ~/.jackal/skills/<name>/SKILL.md.",
            ]
        )

    lines = [f"Skills ({len(skills)}):", ""]
    for skill in skills:
        source = str(skill.get("source", ""))
        if source == "project":
            tag = " [project]"
        elif source == "user":
            tag = " [user]"
        elif source == "builtin":
            tag = " [built-in]"
        else:
            tag = ""

        name = str(skill.get("name", "")).strip()
        desc = str(skill.get("description", "")).strip()
        lines.append(f"- /skill:{name}{tag} — {desc}")

    lines.append("")
    lines.append(
        "Use /skill:<name> to load a skill, or read the absolute path from the system prompt catalog."
    )
    return "\n".join(lines)
