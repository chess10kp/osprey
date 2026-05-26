"""Project initializer — analyze a Jac project and generate AGENTS.md.

Ported from src/project/project-init.ts. Pure file-I/O + analysis.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Literal

ProjectType = Literal[
    "fullstack", "api", "client-only", "library", "mixed", "non-jac",
]

MAX_SCAN_DEPTH = 5
MAX_JAC_FILES = 100


def _run_quiet(cmd: str, cwd: str) -> str | None:
    try:
        r = subprocess.run(
            cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=10,
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def _scan_files(cwd: str, extensions: list[str], max_depth: int = MAX_SCAN_DEPTH) -> list[str]:
    results: list[str] = []
    skip_dirs = {"node_modules", "__pycache__", ".git", "dist", ".venv", "venv"}

    def walk(dir_path: str, depth: int) -> None:
        if depth > max_depth or len(results) >= MAX_JAC_FILES:
            return
        try:
            entries = sorted(os.listdir(dir_path))
        except OSError:
            return
        for name in entries:
            if len(results) >= MAX_JAC_FILES:
                break
            if name.startswith(".") and name != ".jackal":
                continue
            full = os.path.join(dir_path, name)
            if os.path.isdir(full):
                if name in skip_dirs:
                    continue
                walk(full, depth + 1)
            elif os.path.isfile(full):
                _, ext = os.path.splitext(name)
                if ext in extensions:
                    results.append(os.path.relpath(full, cwd))

    walk(cwd, 0)
    return sorted(results)


def _classify_project(jac_files: list[str], has_jac_toml: bool, entry_point: str | None) -> ProjectType:
    has_server = any(".sv.jac" in f or "server" in f for f in jac_files)
    has_client = any(".cl.jac" in f or "client" in f for f in jac_files)
    entry = (entry_point or "").lower()
    if has_server and has_client:
        return "fullstack"
    if has_server and not has_client:
        return "api"
    if has_client and not has_server:
        return "client-only"
    if jac_files and "main.jac" in entry:
        return "library"
    if jac_files:
        return "mixed"
    return "non-jac"


def _parse_npm_deps(cwd: str) -> list[str]:
    toml_path = os.path.join(cwd, "jac.toml")
    if not os.path.isfile(toml_path):
        return []
    try:
        with open(toml_path, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return []
    deps: list[str] = []
    in_section = False
    for line in content.splitlines():
        if line.strip() == "[dependencies.npm]":
            in_section = True
            continue
        if in_section and line.strip().startswith("["):
            break
        if in_section:
            m = re.match(r"^(\w[\w.-]*)\s*=", line)
            if m:
                deps.append(m.group(1))
    return deps


def _parse_jac_toml(cwd: str) -> dict:
    toml_path = os.path.join(cwd, "jac.toml")
    if not os.path.isfile(toml_path):
        return {"name": "", "description": "", "entryPoint": None}
    try:
        with open(toml_path, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return {"name": "", "description": "", "entryPoint": None}

    name = ""
    description = ""
    entry_point = None
    for line in content.splitlines():
        m = re.match(r'^name\s*=\s*"([^"]*)"', line)
        if m:
            name = m.group(1)
        m = re.match(r'^description\s*=\s*"([^"]*)"', line)
        if m:
            description = m.group(1)
        m = re.match(r'^entry-point\s*=\s*"([^"]*)"', line)
        if m:
            entry_point = m.group(1)
    return {"name": name, "description": description, "entryPoint": entry_point}


def analyze_project(cwd: str) -> dict:
    """Analyze a project directory and return structured info."""
    resolved = os.path.abspath(cwd)
    toml = _parse_jac_toml(resolved)
    jac_files = _scan_files(resolved, [".jac"])
    python_files = _scan_files(resolved, [".py"])
    npm_deps = _parse_npm_deps(resolved)

    jac_version = _run_quiet("jac --version 2>/dev/null || jaclang --version 2>/dev/null", resolved)
    python_version = _run_quiet("python3 --version", resolved)

    has_tests = (
        any("test" in f or "spec" in f for f in jac_files)
        or any("test" in f for f in python_files)
    )

    project_type = _classify_project(
        jac_files,
        os.path.isfile(os.path.join(resolved, "jac.toml")),
        toml["entryPoint"],
    )

    return {
        "projectName": toml["name"] or os.path.basename(resolved),
        "description": toml["description"],
        "hasJacToml": os.path.isfile(os.path.join(resolved, "jac.toml")),
        "jacTomlEntry": toml["entryPoint"],
        "jacVersion": jac_version,
        "pythonVersion": python_version,
        "jacFiles": jac_files,
        "pythonFiles": python_files,
        "hasVenv": os.path.isdir(os.path.join(resolved, ".venv")) or os.path.isdir(os.path.join(resolved, "venv")),
        "hasGit": os.path.isdir(os.path.join(resolved, ".git")),
        "hasTests": has_tests,
        "hasReadme": os.path.isfile(os.path.join(resolved, "README.md")) or os.path.isfile(os.path.join(resolved, "readme.md")),
        "hasAgentsMd": os.path.isfile(os.path.join(resolved, "AGENTS.md")),
        "hasJackalConfig": os.path.isfile(os.path.join(resolved, ".jackal")),
        "npmDeps": npm_deps,
        "projectType": project_type,
    }


def generate_agents_md(info: dict) -> str:
    """Generate an AGENTS.md template from project analysis."""
    lines: list[str] = []

    lines.append(f"# {info.get('projectName') or 'Project'}")
    lines.append("")
    desc = info.get("description")
    if desc:
        lines.append(desc)
        lines.append("")

    lines.append("## Project Type")
    lines.append("")
    lines.append(f"**{info.get('projectType', 'mixed')}** Jac project.")
    lines.append("")

    # Stack
    lines.append("## Stack")
    lines.append("")
    if info.get("jacVersion"):
        lines.append(f"- **Jac:** {info['jacVersion']}")
    if info.get("pythonVersion"):
        lines.append(f"- **Python:** {info['pythonVersion']}")
    if info.get("hasJacToml"):
        lines.append("- **Config:** `jac.toml`")
    if info.get("hasVenv"):
        lines.append("- **Virtual env:** `.venv/`")
    npm_deps = info.get("npmDeps", [])
    if npm_deps:
        lines.append(f"- **NPM deps:** {', '.join(npm_deps)}")
    lines.append("")

    # Key files
    lines.append("## Key Files")
    lines.append("")
    entry = info.get("jacTomlEntry")
    if entry:
        lines.append(f"- **Entry point:** `{entry}`")

    jac_files = info.get("jacFiles", [])
    server_files = [f for f in jac_files if ".sv.jac" in f or "server" in f]
    client_files = [f for f in jac_files if ".cl.jac" in f or "client" in f]
    walker_files = [f for f in jac_files if "walker" in f]
    main_files = [f for f in jac_files if f.endswith("main.jac") or f.endswith("app.jac")]
    test_files = [f for f in jac_files if "test" in f or "spec" in f]

    def _fmt_list(files: list[str], limit: int = 5) -> str:
        shown = ", ".join(f"`{f}`" for f in files[:limit])
        if len(files) > limit:
            shown += f" +{len(files) - limit} more"
        return shown

    if main_files:
        lines.append(f"- **Main:** {_fmt_list(main_files)}")
    if server_files:
        lines.append(f"- **Server ({len(server_files)}):** {_fmt_list(server_files)}")
    if client_files:
        lines.append(f"- **Client ({len(client_files)}):** {_fmt_list(client_files)}")
    if walker_files:
        lines.append(f"- **Walkers:** {_fmt_list(walker_files)}")
    if test_files:
        lines.append(f"- **Tests:** {_fmt_list(test_files)}")

    other = [f for f in jac_files if f not in set(main_files + server_files + client_files + walker_files + test_files)]
    if other:
        lines.append(f"- **Other Jac ({len(other)}):** {_fmt_list(other, 8)}")
    lines.append("")

    # Counts
    lines.append("## File Counts")
    lines.append("")
    lines.append(f"- `.jac` files: {len(jac_files)}")
    lines.append(f"- `.py` files: {len(info.get('pythonFiles', []))}")
    lines.append("")

    # Guidelines
    lines.append("## Development Guidelines")
    lines.append("")
    lines.append("- Run `jac check` after editing `.jac` files")
    if info.get("hasTests"):
        lines.append("- Run `jac test` before committing")
    lines.append("- Use `jac format` to keep code style consistent")
    if info.get("projectType") == "fullstack":
        lines.append("- Server code in `.sv.jac`, client code in `.cl.jac` — follow Jac fullstack conventions")
    if info.get("hasGit"):
        lines.append("- Commit with clear messages; prefer small, focused changes")
    lines.append("")

    # Jackal config suggestion
    if not info.get("hasJackalConfig"):
        lines.append("## Jackal Configuration")
        lines.append("")
        lines.append("No `.jackal` config found. Create one with:")
        lines.append("```json")
        lines.append(json.dumps({
            "autocheck": True,
            "autoformat": True,
            "maxFixAttempts": 3,
            "autoCompact": {"enabled": True, "thresholdPercent": 80},
            "sessions": {"autoSave": True, "maxCount": 50, "retentionDays": 30},
        }, indent=2))
        lines.append("```")
        lines.append("")

    return "\n".join(lines)


def run_project_init(
    cwd: str, force: bool = False, lean: bool = False,
) -> dict:
    """Run /init — analyze project and write/update AGENTS.md."""
    info = analyze_project(cwd)
    agents_path = os.path.join(os.path.abspath(cwd), "AGENTS.md")

    if os.path.isfile(agents_path) and not force:
        try:
            with open(agents_path, encoding="utf-8") as f:
                existing = f.read()
        except OSError:
            existing = ""
        if "<!-- jackal-init -->" in existing:
            return {
                "written": False,
                "path": agents_path,
                "content": "AGENTS.md already has a Jackal init section. Use --force to overwrite.",
            }
        return {
            "written": False,
            "path": agents_path,
            "content": "AGENTS.md already exists. Use --force to overwrite.",
        }

    md = generate_agents_md(info)
    if lean:
        md = "\n".join(md.splitlines()[:30])

    final = f"<!-- jackal-init -->\n{md}"

    try:
        with open(agents_path, "w", encoding="utf-8") as f:
            f.write(final)
    except OSError as exc:
        return {
            "written": False,
            "path": agents_path,
            "content": f"Failed to write AGENTS.md: {exc}",
        }

    return {"written": True, "path": agents_path, "content": final}
