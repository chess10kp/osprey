"""Skills catalog compatibility API for the all-Jac harness.

Implementation is split into skills_support (frontmatter, matching,
validation, and single-file loading) and skills_discovery (directory walks,
roots, and precedence merging). This module deliberately re-exports their
helpers so existing imports from agent.skills remain unchanged.
"""

import os;
import tempfile;
import shutil;
import from .skills_support {
    MAX_NAME_LENGTH,
    MAX_DESCRIPTION_LENGTH,
    IGNORE_FILE_NAMES,
    _base_name,
    _dir_name,
    _rel_path,
    _abs_path,
    _canonical,
    _is_abs,
    _user_home,
    _parse_scalar,
    parse_frontmatter,
    frontmatter_string,
    _gitignore_parse_rules,
    _load_ignore_rules,
    _match_ignore_pattern,
    _validate_name,
    _validate_description,
    _warning,
    _load_skill_from_file,
}
import from .skills_discovery {
    _load_skills_from_dir,
    load_skills_from_dir,
    _find_project_skills_dir,
    _normalize_path,
    _resolve_skill_path,
    _path_under,
    _get_source,
    _add_loaded,
    _resolve_package_root,
    _skill_sort_key,
    load_jackal_skills,
}


# ========================== prompt formatting ============================


def _escape_xml(s: str) -> str {
    out = s.replace("&", "&amp;");
    out = out.replace("<", "&lt;");
    out = out.replace(">", "&gt;");
    out = out.replace('"', "&quot;");
    out = out.replace("'", "&apos;");
    return out;
}


"""Render the <available_skills> system-prompt block ('' when all hidden)."""
def format_skills_for_prompt(skills: list) -> str {
    visible: list = [];
    for s in skills {
        if not s.get("disableModelInvocation", False) {
            visible.append(s);
        }
    }
    if not visible {
        return "";
    }
    lines: list[str] = [];
    lines.append("\n\nThe following skills provide specialized instructions for specific tasks.");
    lines.append("Use the read tool to load a skill's file when the task matches its description.");
    lines.append(
        "When a skill file references a relative path, resolve it against the skill directory "
        + "(parent of SKILL.md / dirname of the path) and use that absolute path in tool commands."
    );
    lines.append("");
    lines.append("<available_skills>");
    for s in visible {
        lines.append("  <skill>");
        lines.append("    <name>" + _escape_xml(str(s.get("name", ""))) + "</name>");
        lines.append(
            "    <description>" + _escape_xml(str(s.get("description", ""))) + "</description>"
        );
        lines.append("    <location>" + _escape_xml(str(s.get("filePath", ""))) + "</location>");
        lines.append("  </skill>");
    }
    lines.append("</available_skills>");
    return "\n".join(lines);
}


"""Append the skills catalog to a system prompt (unchanged when empty)."""
def append_skills_to_prompt(system_prompt: str, skills: list) -> str {
    catalog = format_skills_for_prompt(skills);
    if catalog {
        return system_prompt + catalog;
    }
    return system_prompt;
}


# ========================= /skill:name expansion =========================


"""Expand '/skill:name args...' into an inline <skill> block + args.

Unchanged text when the input is not a /skill: command, the name is
unknown, or the backing file became unreadable."""
def expand_skill_command(text: str, skills: list) -> str {
    if not text.startswith("/skill:") {
        return text;
    }
    space = text.find(" ");
    if space != -1 {
        skill_name = text[7:space];
        args = text[space + 1:].strip();
    } else {
        skill_name = text[7:];
        args = "";
    }

    found: dict | None = None;
    for s in skills {
        if str(s.get("name", "")) == skill_name {
            found = s;
            break;
        }
    }
    if found is None {
        return text;
    }
    skill_path = str(found.get("filePath", ""));
    skill_base = str(found.get("baseDir", ""));
    try {
        fh = open(skill_path, encoding="utf-8");
        try {
            raw = fh.read();
        } finally {
            fh.close();
        }
        (_fm, body) = parse_frontmatter(raw);
        block = (
            '<skill name="' + skill_name + '" location="' + skill_path + '">\n'
            + "References are relative to " + skill_base + ".\n\n"
            + body.strip()
            + "\n</skill>"
        );
        if args {
            return block + "\n\n" + args;
        }
        return block;
    } except Exception {
        return text;
    }
}


# ====================== builtin lookup + allowlist =======================


"""Stripped body of a built-in skill's SKILL.md ('' when absent/broken)."""
def load_skill_by_dir(dir_name: str, package_root: str = "") -> str {
    pkg_base = package_root if package_root else _resolve_package_root();
    fpath = os.path.join(pkg_base, "pi", "skills", dir_name, "SKILL.md");
    if not os.path.isfile(fpath) {
        return "";
    }
    try {
        fh = open(fpath, encoding="utf-8");
        try {
            raw = fh.read();
        } finally {
            fh.close();
        }
        (_fm, body) = parse_frontmatter(raw);
        return body.strip();
    } except Exception {
        return "";
    }
}


"""Read-permission seeds for loaded skills: exact files plus rooted dirs."""
def skill_read_allowlist(skills: list) -> dict {
    files: list[str] = [];
    roots: list[str] = [];
    for s in skills {
        files.append(_abs_path(str(s.get("filePath", ""))));
        roots.append(_abs_path(str(s.get("baseDir", ""))) + os.sep);
    }
    return {"files": files, "roots": roots};
}
