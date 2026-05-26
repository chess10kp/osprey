"""Skills discovery, loading, formatting — Python toolchain for Jackal.

Ported from src/project/skills.ts. Pure file-I/O + logic; no npm dependencies.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

# Frontmatter parser lives in orchestration
_orch_dir = os.path.join(os.path.dirname(__file__), "..", "orchestration")
if _orch_dir not in sys.path:
    sys.path.insert(0, _orch_dir)

from _frontmatter_toolchain import parse_frontmatter, frontmatter_string  # noqa: E402

MAX_NAME_LENGTH = 64
MAX_DESCRIPTION_LENGTH = 1024
IGNORE_FILE_NAMES = (".gitignore", ".ignore", ".fdignore")

SkillSource = Literal["builtin", "user", "project", "path"]


@dataclass
class Skill:
    name: str
    description: str
    filePath: str
    baseDir: str
    source: SkillSource
    disableModelInvocation: bool


@dataclass
class SkillDiagnostic:
    type: str  # "warning" | "collision"
    message: str
    path: str
    collision: dict | None = None


@dataclass
class LoadSkillsResult:
    skills: list[Skill] = field(default_factory=list)
    diagnostics: list[SkillDiagnostic] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Gitignore-style matching (lightweight, no external dependency)
# ---------------------------------------------------------------------------

def _gitignore_parse_rules(content: str, prefix: str) -> list[str]:
    """Parse gitignore content, prefixing with *prefix* for sub-dir rules."""
    rules: list[str] = []
    for line in content.splitlines():
        trimmed = line.strip()
        if not trimmed or (trimmed.startswith("#") and not trimmed.startswith("\\#")):
            continue
        pattern = line
        negated = False
        if pattern.startswith("!"):
            negated = True
            pattern = pattern[1:]
        elif pattern.startswith("\\!"):
            pattern = pattern[1:]
        if pattern.startswith("/"):
            pattern = pattern[1:]
        prefixed = f"{prefix}{pattern}" if prefix else pattern
        rules.append(f"!{prefixed}" if negated else prefixed)
    return rules


def _load_ignore_rules(root_dir: str, subdir: str) -> list[str]:
    """Load ignore rules from *subdir* relative to *root_dir*."""
    rel = os.path.relpath(subdir, root_dir).replace(os.sep, "/")
    prefix = f"{rel}/" if rel != "." else ""
    rules: list[str] = []
    for fname in IGNORE_FILE_NAMES:
        fpath = os.path.join(subdir, fname)
        if os.path.isfile(fpath):
            try:
                with open(fpath, encoding="utf-8") as f:
                    rules.extend(_gitignore_parse_rules(f.read(), prefix))
            except OSError:
                pass
    return rules


def _match_ignore_pattern(path: str, rules: list[str]) -> bool:
    """Minimal gitignore-style match. Returns True if *path* should be ignored."""
    import fnmatch

    result = False
    for rule in rules:
        negated = rule.startswith("!")
        pattern = rule[1:] if negated else rule
        # directory-only patterns (trailing /)
        dir_only = pattern.endswith("/")
        if dir_only:
            pattern = pattern.rstrip("/")

        if pattern.startswith("**/"):
            # match anywhere
            sub = pattern[3:]
            if fnmatch.fnmatch(os.path.basename(path), sub):
                result = not negated
        elif "/" in pattern:
            if fnmatch.fnmatch(path, pattern):
                result = not negated
        else:
            # match basename
            if fnmatch.fnmatch(os.path.basename(path), pattern):
                result = not negated
    return result


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def _validate_name(name: str) -> list[str]:
    errors: list[str] = []
    if len(name) > MAX_NAME_LENGTH:
        errors.append(f"name exceeds {MAX_NAME_LENGTH} characters ({len(name)})")
    if not re.fullmatch(r"[a-z0-9-]+", name):
        errors.append("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)")
    if name.startswith("-") or name.endswith("-"):
        errors.append("name must not start or end with a hyphen")
    if "--" in name:
        errors.append("name must not contain consecutive hyphens")
    return errors


def _validate_description(description: str | None) -> list[str]:
    errors: list[str] = []
    if not description or description.strip() == "":
        errors.append("description is required")
    elif len(description) > MAX_DESCRIPTION_LENGTH:
        errors.append(f"description exceeds {MAX_DESCRIPTION_LENGTH} characters ({len(description)})")
    return errors


# ---------------------------------------------------------------------------
# Load single skill file
# ---------------------------------------------------------------------------

def _load_skill_from_file(
    file_path: str, source: SkillSource
) -> tuple[Skill | None, list[SkillDiagnostic]]:
    diagnostics: list[SkillDiagnostic] = []
    try:
        with open(file_path, encoding="utf-8") as f:
            raw = f.read()
        parsed = parse_frontmatter(raw)
        fm = parsed.frontmatter
        skill_dir = os.path.dirname(file_path)
        parent_name = os.path.basename(skill_dir)
        desc = frontmatter_string(fm.get("description"))
        disable_invocation = (
            str(frontmatter_string(fm.get("disable-model-invocation")) or "").lower() == "true"
        )

        for err in _validate_description(desc):
            diagnostics.append(SkillDiagnostic(type="warning", message=err, path=file_path))

        name = (frontmatter_string(fm.get("name")) or "").strip() or parent_name

        for err in _validate_name(name):
            diagnostics.append(SkillDiagnostic(type="warning", message=err, path=file_path))

        if not desc or not desc.strip():
            return None, diagnostics

        return Skill(
            name=name,
            description=desc.strip(),
            filePath=file_path,
            baseDir=skill_dir,
            source=source,
            disableModelInvocation=disable_invocation,
        ), diagnostics
    except Exception as exc:
        diagnostics.append(SkillDiagnostic(
            type="warning", message=str(exc), path=file_path,
        ))
        return None, diagnostics


# ---------------------------------------------------------------------------
# Load from directory (recursive)
# ---------------------------------------------------------------------------

def _load_skills_from_dir(
    dir_path: str,
    source: SkillSource,
    include_root_files: bool = True,
    ignore_rules: list[str] | None = None,
    root_dir: str | None = None,
) -> LoadSkillsResult:
    skills: list[Skill] = []
    diagnostics: list[SkillDiagnostic] = []

    if not os.path.isdir(dir_path):
        return LoadSkillsResult(skills, diagnostics)

    root = root_dir or dir_path
    rules = list(ignore_rules) if ignore_rules else []
    rules.extend(_load_ignore_rules(root, dir_path))

    try:
        entries = sorted(os.listdir(dir_path))
    except OSError:
        return LoadSkillsResult(skills, diagnostics)

    # 1) Check for SKILL.md at this level
    for name in entries:
        if name != "SKILL.md":
            continue
        full = os.path.join(dir_path, name)
        if not os.path.isfile(full):
            continue
        rel = os.path.relpath(full, root).replace(os.sep, "/")
        if _match_ignore_pattern(rel, rules):
            continue
        skill, diag = _load_skill_from_file(full, source)
        if skill:
            skills.append(skill)
        diagnostics.extend(diag)
        return LoadSkillsResult(skills, diagnostics)

    # 2) Recurse subdirectories and check root .md files
    for name in entries:
        if name.startswith(".") or name == "node_modules":
            continue
        full = os.path.join(dir_path, name)

        if os.path.isdir(full):
            rel = os.path.relpath(full, root).replace(os.sep, "/") + "/"
            if _match_ignore_pattern(rel, rules):
                continue
            sub = _load_skills_from_dir(full, source, False, rules, root)
            skills.extend(sub.skills)
            diagnostics.extend(sub.diagnostics)
        elif include_root_files and name.endswith(".md") and os.path.isfile(full):
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if _match_ignore_pattern(rel, rules):
                continue
            skill, diag = _load_skill_from_file(full, source)
            if skill:
                skills.append(skill)
            diagnostics.extend(diag)

    return LoadSkillsResult(skills, diagnostics)


# ---------------------------------------------------------------------------
# Public: load from single dir
# ---------------------------------------------------------------------------

def load_skills_from_dir(dir_path: str, source: SkillSource) -> LoadSkillsResult:
    return _load_skills_from_dir(dir_path, source, True)


# ---------------------------------------------------------------------------
# Find .jackal/skills walking up
# ---------------------------------------------------------------------------

def _find_project_skills_dir(cwd: str) -> str | None:
    cur = os.path.abspath(cwd)
    while True:
        candidate = os.path.join(cur, ".jackal", "skills")
        if os.path.isdir(candidate):
            return candidate
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


# ---------------------------------------------------------------------------
# Path normalization for explicit skill paths
# ---------------------------------------------------------------------------

def _normalize_path(p: str) -> str:
    trimmed = p.strip()
    home = os.path.expanduser("~")
    if trimmed == "~":
        return home
    if trimmed.startswith("~/"):
        return os.path.join(home, trimmed[2:])
    if trimmed.startswith("~"):
        return os.path.join(home, trimmed[1:])
    return trimmed


def _resolve_skill_path(p: str, cwd: str) -> str:
    normalized = _normalize_path(p)
    return normalized if os.path.isabs(normalized) else os.path.abspath(os.path.join(cwd, normalized))


# ---------------------------------------------------------------------------
# Public: load all Jackal skills
# ---------------------------------------------------------------------------

def load_jackal_skills(
    cwd: str | None = None,
    package_root: str | None = None,
    agent_dir: str | None = None,
    skill_paths: list[str] | None = None,
    include_defaults: bool = True,
) -> LoadSkillsResult:
    cwd = cwd or os.getcwd()
    package_root = package_root or _resolve_package_root()
    agent_dir = agent_dir or os.path.join(os.path.expanduser("~"), ".jackal")
    skill_paths = skill_paths or []

    skill_map: dict[str, Skill] = {}
    real_path_set: set[str] = set()
    all_diagnostics: list[SkillDiagnostic] = []
    collision_diagnostics: list[SkillDiagnostic] = []

    def _canonical(p: str) -> str:
        try:
            return os.path.realpath(p)
        except OSError:
            return os.path.abspath(p)

    def _add(result: LoadSkillsResult) -> None:
        all_diagnostics.extend(result.diagnostics)
        for skill in result.skills:
            rp = _canonical(skill.filePath)
            if rp in real_path_set:
                continue
            real_path_set.add(rp)
            existing = skill_map.get(skill.name)
            if existing:
                collision_diagnostics.append(SkillDiagnostic(
                    type="collision",
                    message=f'name "{skill.name}" collision',
                    path=skill.filePath,
                    collision={
                        "name": skill.name,
                        "winnerPath": skill.filePath,
                        "loserPath": existing.filePath,
                    },
                ))
            skill_map[skill.name] = skill

    if include_defaults:
        _add(_load_skills_from_dir(os.path.join(package_root, "pi", "skills"), "builtin", True))
        _add(_load_skills_from_dir(os.path.join(agent_dir, "skills"), "user", True))
        proj_dir = _find_project_skills_dir(cwd)
        if proj_dir:
            _add(_load_skills_from_dir(proj_dir, "project", True))

    user_skills_dir = os.path.join(agent_dir, "skills")
    project_skills_dir = _find_project_skills_dir(cwd)

    def _under(target: str, root: str | None) -> bool:
        if not root:
            return False
        nr = os.path.abspath(root)
        if target == nr:
            return True
        return target.startswith(nr + os.sep)

    def _get_source(rp: str) -> SkillSource:
        if _under(rp, user_skills_dir):
            return "user"
        if _under(rp, project_skills_dir):
            return "project"
        return "path"

    for raw in skill_paths:
        rp = _resolve_skill_path(raw, cwd)
        if not os.path.exists(rp):
            all_diagnostics.append(SkillDiagnostic(
                type="warning", message="skill path does not exist", path=rp,
            ))
            continue
        try:
            source = _get_source(rp)
            if os.path.isdir(rp):
                _add(_load_skills_from_dir(rp, source, True))
            elif os.path.isfile(rp) and rp.endswith(".md"):
                skill, diag = _load_skill_from_file(rp, source)
                if skill:
                    _add(LoadSkillsResult([skill], diag))
                else:
                    all_diagnostics.extend(diag)
            else:
                all_diagnostics.append(SkillDiagnostic(
                    type="warning", message="skill path is not a markdown file", path=rp,
                ))
        except Exception as exc:
            all_diagnostics.append(SkillDiagnostic(
                type="warning", message=str(exc), path=rp,
            ))

    sorted_skills = sorted(skill_map.values(), key=lambda s: s.name)
    return LoadSkillsResult(
        skills=sorted_skills,
        diagnostics=all_diagnostics + collision_diagnostics,
    )


# ---------------------------------------------------------------------------
# Format for system prompt
# ---------------------------------------------------------------------------

def _escape_xml(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def _get_attr(obj, key, default=None):
    """Get attribute or dict key — works with both Skill objects and dicts."""
    if isinstance(obj, dict):
        return obj.get(key, default)
    return getattr(obj, key, default)


def format_skills_for_prompt(skills: list) -> str:
    visible = [s for s in skills if not _get_attr(s, "disableModelInvocation", False)]
    if not visible:
        return ""
    lines = [
        "\n\nThe following skills provide specialized instructions for specific tasks.",
        "Use the read tool to load a skill's file when the task matches its description.",
        (
            "When a skill file references a relative path, resolve it against the skill directory "
            "(parent of SKILL.md / dirname of the path) and use that absolute path in tool commands."
        ),
        "",
        "<available_skills>",
    ]
    for s in visible:
        lines.append("  <skill>")
        lines.append(f"    <name>{_escape_xml(_get_attr(s, 'name'))}</name>")
        lines.append(f"    <description>{_escape_xml(_get_attr(s, 'description'))}</description>")
        lines.append(f"    <location>{_escape_xml(_get_attr(s, 'filePath'))}</location>")
        lines.append("  </skill>")
    lines.append("</available_skills>")
    return "\n".join(lines)


def append_skills_to_prompt(system_prompt: str, skills: list) -> str:
    catalog = format_skills_for_prompt(skills)
    return system_prompt + catalog if catalog else system_prompt


# ---------------------------------------------------------------------------
# Expand /skill:name commands
# ---------------------------------------------------------------------------

def expand_skill_command(text: str, skills: list) -> str:
    if not text.startswith("/skill:"):
        return text
    space = text.find(" ")
    skill_name = text[7:space] if space != -1 else text[7:]
    args = text[space + 1:].strip() if space != -1 else ""

    skill = next((s for s in skills if _get_attr(s, "name") == skill_name), None)
    if not skill:
        return text
    skill_path = _get_attr(skill, "filePath")
    skill_base = _get_attr(skill, "baseDir")
    skill_name_val = _get_attr(skill, "name")
    try:
        with open(skill_path, encoding="utf-8") as f:
            raw = f.read()
        parsed = parse_frontmatter(raw)
        block = (
            f'<skill name="{skill_name_val}" location="{skill_path}">\n'
            f"References are relative to {skill_base}.\n\n"
            f"{parsed.body.strip()}\n</skill>"
        )
        return f"{block}\n\n{args}" if args else block
    except Exception:
        return text


# ---------------------------------------------------------------------------
# Load a built-in skill by dir name
# ---------------------------------------------------------------------------

def load_skill_by_dir(dir_name: str, package_root: str | None = None) -> str:
    root = package_root or _resolve_package_root()
    fpath = os.path.join(root, "pi", "skills", dir_name, "SKILL.md")
    if not os.path.isfile(fpath):
        return ""
    try:
        with open(fpath, encoding="utf-8") as f:
            raw = f.read()
        return parse_frontmatter(raw).body.strip()
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# Skill read allowlist
# ---------------------------------------------------------------------------

def skill_read_allowlist(skills: list) -> dict:
    files: list[str] = []
    roots: list[str] = []
    for s in skills:
        files.append(os.path.abspath(_get_attr(s, "filePath")))
        roots.append(os.path.abspath(_get_attr(s, "baseDir")) + os.sep)
    return {"files": files, "roots": roots}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resolve_package_root() -> str:
    env = os.environ.get("JACKAL_AGENT_DIR")
    if env and os.path.isdir(os.path.join(env, "pi", "skills")):
        return os.path.abspath(env)
    # Walk up from this file
    here = os.path.dirname(os.path.abspath(__file__))
    for _ in range(5):
        candidate = os.path.join(here, "pi", "skills")
        if os.path.isdir(candidate):
            return here
        here = os.path.dirname(here)
    return os.getcwd()
