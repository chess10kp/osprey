"""Skills discovery/indexing for the all-Jac harness (ported from
lib/jac/project/_skills_toolchain.py -- the Python source of truth, which
itself ports src/project/skills.ts).

Behavior carried over 1:1:
- Recursive discovery walk: a directory containing SKILL.md terminates that
  branch; otherwise subdirectories are walked (dot-dirs and node_modules
  skipped) plus optional root-level *.md files.
- Lightweight gitignore matching (.gitignore/.ignore/.fdignore) with
  prefixing, negation, **/ anywhere-matches, basename matches.
- Validation: lowercase a-z/0-9/hyphen names <= 64 chars, no leading/
  trailing/double hyphens; required descriptions <= 1024 chars. Problems
  become warning diagnostics, never exceptions.
- Root merging in load_jackal_skills: builtin (package_root/pi/skills),
  user (agent_dir/skills), project (.jackal/skills walked up from cwd) --
  later roots win name collisions; realpath dedup; explicit skill_paths
  (~/ expansion, relative-to-cwd, single .md files or directories).
- Prompt catalog formatting (XML-escaped <available_skills> block,
  disable-model-invocation filtered), /skill:name expansion inlining the
  skill body with relative-path context, load_skill_by_dir, and the
  read allowlist (files + rooted base dirs).

Deviations from the Python toolchain:
- Skill records are plain dicts with keys name/description/filePath/
  baseDir/source/disableModelInvocation (camelCase keys kept so the shape
  matches the legacy bridge contract); results are {"skills": [...],
  "diagnostics": [...]} dicts. Diagnostics carry an explicit null
  "collision" key where the original omitted the field.
- Frontmatter parsing is hand-rolled stdlib here (mirrors
  lib/jac/orchestration/_frontmatter_toolchain.py behavior: --- delimited,
  quoted scalars, inline [a, b] and dash-block lists). No PyYAML.
- os.path.relpath/basename/dirname/realpath are wrapped behind any-typed
  shims (_rel_path/_base_name/_dir_name/_canonical) because the imported
  stubs demand LiteralString/PathLike arguments the Jac checker will not
  take from plain str locals. Semantics unchanged.
- _resolve_package_root cannot walk up from __file__ (no stable __file__
  in compiled Jac modules), so it tries JACKAL_AGENT_DIR, then
  JACKAL_ROOT, then cwd; callers loading real catalogs pass
  package_root explicitly.
"""

import os;
import re;
import fnmatch;
import tempfile;
import shutil;

glob MAX_NAME_LENGTH: int = 64,
     MAX_DESCRIPTION_LENGTH: int = 1024,
     IGNORE_FILE_NAMES: list[str] = [".gitignore", ".ignore", ".fdignore"];


# ============================ path shims =================================


"""str-typed shims over os.path stubs that require PathLike/LiteralString."""
def _base_name(p: any) -> str {
    return str(p).replace(os.sep, "/").rsplit("/", 1)[-1];
}


def _dir_name(p: any) -> str {
    s = str(p).replace(os.sep, "/");
    idx = s.rfind("/");
    if idx == -1 {
        return s;
    }
    if idx == 0 {
        return "/";
    }
    return s[:idx];
}


def _rel_path(target: any, start: any) -> str {
    return str(os.path.relpath(target, start));
}


def _abs_path(p: any) -> str {
    return str(os.path.abspath(p));
}


"""Realpath canonicalization with abspath fallback."""
def _canonical(p: any) -> str {
    try {
        return str(os.path.realpath(p));
    } except OSError {
        return _abs_path(p);
    }
}


def _is_abs(p: any) -> bool {
    return bool(os.path.isabs(p));
}


def _user_home() -> str {
    tilde: any = "~";
    return str(os.path.expanduser(tilde));
}


# ============================== frontmatter ==============================


def _parse_scalar(value: str) -> any {
    trimmed = value.strip();
    if not trimmed {
        return "";
    }
    if (trimmed.startswith('"') and trimmed.endswith('"')) or (
        trimmed.startswith("'") and trimmed.endswith("'")
    ) {
        return trimmed[1:-1];
    }
    if trimmed.startswith("[") and trimmed.endswith("]") {
        inner = trimmed[1:-1].strip();
        if not inner {
            return [];
        }
        parts: list[str] = [];
        for part in inner.split(",") {
            piece = part.strip().strip("\"'");
            if piece {
                parts.append(piece);
            }
        }
        return parts;
    }
    return trimmed;
}


"""Parse --- delimited YAML-like frontmatter; returns (metadata, body).

Mirrors orchestration/_frontmatter_toolchain.parse_frontmatter: CRLF
normalized, missing terminator keeps the whole text as body, dash-block
lists collect under the preceding bare key."""
def parse_frontmatter(content: str) -> tuple[dict, str] {
    fm: dict = {};
    normalized = content.replace("\r\n", "\n");
    if not normalized.startswith("---") {
        return (fm, normalized);
    }
    end_index = normalized.find("\n---", 3);
    if end_index == -1 {
        return (fm, normalized);
    }
    block = normalized[4:end_index];
    body = normalized[end_index + 4:].strip();

    current_key = "";
    list_items: list[str] = [];
    for raw_line in block.split("\n") {
        line = raw_line.rstrip();
        list_match = re.match(r"^\s*-\s+(.*)$", line);
        if list_match and current_key {
            list_items.append(str(list_match.group(1)).strip().strip("\"'").strip("'\""));
            continue;
        }
        # Flush any pending dash-block collection.
        if current_key and list_items {
            fm[current_key] = list_items[:];
        }
        list_items = [];
        current_key = "";
        key_match = re.match(r"^([\w-]+):\s*(.*)$", line);
        if not key_match {
            continue;
        }
        key = str(key_match.group(1));
        value = str(key_match.group(2) or "");
        if not value.strip() {
            current_key = key;
            continue;
        }
        fm[key] = _parse_scalar(value);
    }
    if current_key and list_items {
        fm[current_key] = list_items[:];
    }
    return (fm, body);
}


"""Coerce a frontmatter value to display text (lists join with ', ')."""
def frontmatter_string(value: any) -> str | None {
    if value is None {
        return None;
    }
    if isinstance(value, list) {
        parts: list[str] = [];
        for item in value {
            parts.append(str(item));
        }
        return ", ".join(parts);
    }
    return str(value);
}


# ========================= gitignore-lite matching ========================


"""Parse gitignore content, prefixing with *prefix* for sub-dir rules."""
def _gitignore_parse_rules(content: str, prefix: str) -> list[str] {
    rules: list[str] = [];
    for line in content.splitlines() {
        trimmed = line.strip();
        if not trimmed or (trimmed.startswith("#") and not trimmed.startswith("\\#")) {
            continue;
        }
        pattern = line;
        negated = False;
        if pattern.startswith("!") {
            negated = True;
            pattern = pattern[1:];
        } elif pattern.startswith("\\!") {
            pattern = pattern[1:];
        }
        if pattern.startswith("/") {
            pattern = pattern[1:];
        }
        prefixed = prefix + pattern if prefix else pattern;
        if negated {
            rules.append("!" + prefixed);
        } else {
            rules.append(prefixed);
        }
    }
    return rules;
}


"""Load ignore rules from *subdir* relative to *root_dir*."""
def _load_ignore_rules(root_dir: str, subdir: str) -> list[str] {
    rel = _rel_path(subdir, root_dir).replace(os.sep, "/");
    prefix = rel + "/" if rel != "." else "";
    rules: list[str] = [];
    for fname in IGNORE_FILE_NAMES {
        fpath = os.path.join(subdir, fname);
        if not os.path.isfile(fpath) {
            continue;
        }
        fh = None;
        try {
            fh = open(fpath, encoding="utf-8");
            rules.extend(_gitignore_parse_rules(fh.read(), prefix));
        } except (OSError, UnicodeDecodeError) {
            # Unreadable ignore files contribute no rules.
        } finally {
            if fh is not None {
                fh.close();
            }
        }
    }
    return rules;
}


"""Minimal gitignore-style match; True when *path* should be ignored."""
def _match_ignore_pattern(path: str, rules: list) -> bool {
    result = False;
    for rule in rules {
        rule_str = str(rule);
        negated = rule_str.startswith("!");
        pattern = rule_str[1:] if negated else rule_str;
        dir_only = pattern.endswith("/");
        if dir_only {
            pattern = pattern.rstrip("/");
        }
        if pattern.startswith("**/") {
            # Match anywhere in the tree.
            sub = pattern[3:];
            if fnmatch.fnmatch(_base_name(path), sub) {
                result = not negated;
            }
        } elif "/" in pattern {
            if fnmatch.fnmatch(path, pattern) {
                result = not negated;
            }
        } else {
            # Match basename.
            if fnmatch.fnmatch(_base_name(path), pattern) {
                result = not negated;
            }
        }
    }
    return result;
}


# ============================== validation ===============================


def _validate_name(name: str) -> list[str] {
    errors: list[str] = [];
    if len(name) > MAX_NAME_LENGTH {
        errors.append(f"name exceeds {MAX_NAME_LENGTH} characters ({len(name)})");
    }
    if re.fullmatch(r"[a-z0-9-]+", name) is None {
        errors.append("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)");
    }
    if name.startswith("-") or name.endswith("-") {
        errors.append("name must not start or end with a hyphen");
    }
    if "--" in name {
        errors.append("name must not contain consecutive hyphens");
    }
    return errors;
}


def _validate_description(description: str | None) -> list[str] {
    errors: list[str] = [];
    if not description or description.strip() == "" {
        errors.append("description is required");
    } elif len(description) > MAX_DESCRIPTION_LENGTH {
        errors.append(
            f"description exceeds {MAX_DESCRIPTION_LENGTH} characters ({len(description)})"
        );
    }
    return errors;
}


# =========================== single skill load ===========================


def _warning(message: str, path: str) -> dict {
    return {"type": "warning", "message": message, "path": path, "collision": None};
}


"""Load one SKILL.md into a skill dict; (None, warnings) when unusable.

Missing descriptions exclude the skill (after recording the warning);
bad names warn but keep the skill, mirroring the legacy loader."""
def _load_skill_from_file(file_path: str, source: str) -> tuple[dict | None, list] {
    diagnostics: list = [];
    result: dict | None = None;
    try {
        fh = open(file_path, encoding="utf-8");
        try {
            raw = fh.read();
        } finally {
            fh.close();
        }
        (fm, _body) = parse_frontmatter(raw);
        skill_dir = _dir_name(file_path);
        parent_name = _base_name(skill_dir);
        desc = frontmatter_string(fm.get("description"));
        disable_raw = frontmatter_string(fm.get("disable-model-invocation"));
        disable_invocation = str(disable_raw or "").lower() == "true";

        for err in _validate_description(desc) {
            diagnostics.append(_warning(err, file_path));
        }

        raw_name = frontmatter_string(fm.get("name"));
        name: str = (raw_name or "").strip();
        if not name {
            name = parent_name;
        }
        for err in _validate_name(name) {
            diagnostics.append(_warning(err, file_path));
        }

        if not desc or not str(desc).strip() {
            return (None, diagnostics);
        }
        result = {
            "name": name,
            "description": str(desc).strip(),
            "filePath": file_path,
            "baseDir": skill_dir,
            "source": source,
            "disableModelInvocation": disable_invocation,
        };
    } except Exception as exc {
        diagnostics.append(_warning(str(exc), file_path));
        return (None, diagnostics);
    }
    return (result, diagnostics);
}


# ============================ directory walk =============================


"""Recursive discovery under *dir_path*.

A SKILL.md at a level claims that branch (its own file only); otherwise
each non-hidden, non-node_modules subdir recurses and root-level *.md
files load when include_root_files. Returns
{"skills": [...], "diagnostics": [...]}."""
def _load_skills_from_dir(
    dir_path: str,
    source: str,
    include_root_files: bool = True,
    ignore_rules: list | None = None,
    root_dir: str = "",
) -> dict {
    skills: list = [];
    diagnostics: list = [];
    empty: dict = {"skills": skills, "diagnostics": diagnostics};
    if not os.path.isdir(dir_path) {
        return empty;
    }
    base = root_dir if root_dir else dir_path;
    rules: list = list(ignore_rules) if ignore_rules else [];
    rules.extend(_load_ignore_rules(base, dir_path));

    try {
        entries = sorted(os.listdir(dir_path));
    } except OSError {
        return empty;
    }

    # 1) SKILL.md at this level claims the branch.
    for name in entries {
        if name != "SKILL.md" {
            continue;
        }
        full = os.path.join(dir_path, name);
        if not os.path.isfile(full) {
            continue;
        }
        rel = _rel_path(full, base).replace(os.sep, "/");
        if _match_ignore_pattern(rel, rules) {
            continue;
        }
        (skill, diag) = _load_skill_from_file(full, source);
        if skill is not None {
            skills.append(skill);
        }
        diagnostics.extend(diag);
        return {"skills": skills, "diagnostics": diagnostics};
    }

    # 2) Recurse subdirectories and pick up root-level *.md files.
    for name in entries {
        if name.startswith(".") or name == "node_modules" {
            continue;
        }
        full = os.path.join(dir_path, name);
        if os.path.isdir(full) {
            rel = _rel_path(full, base).replace(os.sep, "/") + "/";
            if _match_ignore_pattern(rel, rules) {
                continue;
            }
            sub = _load_skills_from_dir(full, source, False, rules, base);
            sub_skills: list = sub["skills"];
            sub_diags: list = sub["diagnostics"];
            skills.extend(sub_skills);
            diagnostics.extend(sub_diags);
        } elif include_root_files and name.endswith(".md") and os.path.isfile(full) {
            rel = _rel_path(full, base).replace(os.sep, "/");
            if _match_ignore_pattern(rel, rules) {
                continue;
            }
            (skill, diag) = _load_skill_from_file(full, source);
            if skill is not None {
                skills.append(skill);
            }
            diagnostics.extend(diag);
        }
    }
    return {"skills": skills, "diagnostics": diagnostics};
}


"""Public single-directory load."""
def load_skills_from_dir(dir_path: str, source: str) -> dict {
    return _load_skills_from_dir(dir_path, source, True);
}


# ======================= roots, paths, precedence ========================


"""Nearest ancestor dir (walked up from cwd) holding .jackal/skills, else ''."""
def _find_project_skills_dir(cwd: str) -> str {
    cur = _abs_path(cwd);
    for _hop in range(256) {
        candidate = os.path.join(cur, ".jackal", "skills");
        if os.path.isdir(candidate) {
            return candidate;
        }
        parent = _dir_name(cur);
        if parent == cur {
            return "";
        }
        cur = parent;
    }
    return "";
}


def _normalize_path(p: str) -> str {
    trimmed = p.strip();
    home = _user_home();
    if trimmed == "~" {
        return home;
    }
    if trimmed.startswith("~/") {
        return os.path.join(home, trimmed[2:]);
    }
    if trimmed.startswith("~") {
        return os.path.join(home, trimmed[1:]);
    }
    return trimmed;
}


def _resolve_skill_path(p: str, cwd: str) -> str {
    normalized = _normalize_path(p);
    if _is_abs(normalized) {
        return normalized;
    }
    return _abs_path(os.path.join(cwd, normalized));
}


def _path_under(target: str, base_root: str) -> bool {
    if not base_root {
        return False;
    }
    nr = _abs_path(base_root);
    if target == nr {
        return True;
    }
    return target.startswith(nr + os.sep);
}


def _get_source(rp: str, user_dir: str, proj_dir: str) -> str {
    if _path_under(rp, user_dir) {
        return "user";
    }
    if _path_under(rp, proj_dir) {
        return "project";
    }
    return "path";
}


"""Merge one load result: realpath dedup, later-root-wins collisions."""
def _add_loaded(result: dict, skill_map: dict, real_paths: set,
                all_diags: list, collision_diags: list) {
    res_diags: list = result["diagnostics"];
    all_diags.extend(res_diags);
    res_skills: list = result["skills"];
    for skill in res_skills {
        rp = _canonical(str(skill["filePath"]));
        if rp in real_paths {
            continue;
        }
        real_paths.add(rp);
        existing: dict | None = skill_map.get(str(skill["name"]));
        if existing is not None {
            collision_diags.append({
                "type": "collision",
                "message": 'name "' + str(skill["name"]) + '" collision',
                "path": str(skill["filePath"]),
                "collision": {
                    "name": str(skill["name"]),
                    "winnerPath": str(skill["filePath"]),
                    "loserPath": str(existing["filePath"]),
                },
            });
        }
        skill_map[str(skill["name"])] = skill;
    }
}


def _resolve_package_root() -> str {
    env = os.environ.get("JACKAL_AGENT_DIR");
    if env and os.path.isdir(os.path.join(env, "pi", "skills")) {
        return _abs_path(env);
    }
    root_env = os.environ.get("JACKAL_ROOT");
    if root_env and os.path.isdir(os.path.join(root_env, "pi", "skills")) {
        return _abs_path(root_env);
    }
    return os.getcwd();
}


def _skill_sort_key(skill: dict) -> str {
    return str(skill.get("name", ""));
}


"""Load every visible skill for a session, merged and name-sorted.

Roots (when include_defaults): builtin skills under
<package_root>/pi/skills, user skills under <agent_dir>/skills, and the
project's nearest .jackal/skills above cwd -- later roots override earlier
on name collisions. Explicit skill_paths add ~/ or cwd-relative files/dirs
tagged user/project/path by location. Result: {"skills": [...],
"diagnostics": [warnings..., collisions...]} with skills sorted by name."""
def load_jackal_skills(
    cwd: str = "",
    package_root: str = "",
    agent_dir: str = "",
    skill_paths: list | None = None,
    include_defaults: bool = True,
) -> dict {
    base_cwd = cwd if cwd else os.getcwd();
    pkg_root = package_root if package_root else _resolve_package_root();
    home_dir = agent_dir if agent_dir else os.path.join(_user_home(), ".jackal");
    paths: list = skill_paths if skill_paths is not None else [];

    skill_map: dict = {};
    real_paths: set = set();
    all_diags: list = [];
    collision_diags: list = [];

    user_skills_dir = os.path.join(home_dir, "skills");
    project_skills_dir = _find_project_skills_dir(base_cwd);

    if include_defaults {
        _add_loaded(
            _load_skills_from_dir(os.path.join(pkg_root, "pi", "skills"), "builtin"),
            skill_map, real_paths, all_diags, collision_diags,
        );
        _add_loaded(
            _load_skills_from_dir(user_skills_dir, "user"),
            skill_map, real_paths, all_diags, collision_diags,
        );
        if project_skills_dir {
            _add_loaded(
                _load_skills_from_dir(project_skills_dir, "project"),
                skill_map, real_paths, all_diags, collision_diags,
            );
        }
    }

    for raw in paths {
        rp = _resolve_skill_path(str(raw), base_cwd);
        try {
            if not os.path.exists(rp) {
                all_diags.append(_warning("skill path does not exist", rp));
                continue;
            }
            source = _get_source(rp, user_skills_dir, project_skills_dir);
            if os.path.isdir(rp) {
                _add_loaded(
                    _load_skills_from_dir(rp, source),
                    skill_map, real_paths, all_diags, collision_diags,
                );
            } elif os.path.isfile(rp) and rp.endswith(".md") {
                (skill, diag) = _load_skill_from_file(rp, source);
                if skill is not None {
                    _add_loaded(
                        {"skills": [skill], "diagnostics": diag},
                        skill_map, real_paths, all_diags, collision_diags,
                    );
                } else {
                    all_diags.extend(diag);
                }
            } else {
                all_diags.append(_warning("skill path is not a markdown file", rp));
            }
        } except Exception as exc {
            all_diags.append(_warning(str(exc), rp));
        }
    }

    ordered = sorted(list(skill_map.values()), key=_skill_sort_key);
    return {"skills": ordered, "diagnostics": all_diags + collision_diags};
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
