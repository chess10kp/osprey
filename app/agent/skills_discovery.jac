"""Directory discovery and precedence merging for the skills catalog.

The public functions are re-exported by agent.skills. Keeping discovery
separate from parsing makes the compatibility module small without changing
its import surface or merge behavior.
"""

import os;
import from .skills_support {
    _abs_path,
    _base_name,
    _canonical,
    _dir_name,
    _load_ignore_rules,
    _load_skill_from_file,
    _match_ignore_pattern,
    _rel_path,
    _user_home,
    _is_abs,
    _warning,
}


# ============================ directory walk =============================


"""Recursive discovery under *dir_path*.

A SKILL.md at a level claims that branch (its own file only); otherwise
each non-hidden, non-node_modules subdir recurses and root-level *.md
files load when include_root_files. Returns
{"skills": [...], "diagnostics": [...]}.
"""
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
