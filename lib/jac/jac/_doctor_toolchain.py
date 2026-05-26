"""Jac doctor — shared by doctor.jac and the TypeScript toolchain bridge."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from _cli_toolchain import find_jac_binary

_SKIP_DIRS = {
    "node_modules",
    ".git",
    ".jac",
    "__pycache__",
    "dist",
    "build",
    "reference",
}


def _find_jac_toml(cwd: str) -> str:
    cur = Path(cwd).resolve()
    while True:
        cand = cur / "jac.toml"
        if cand.is_file():
            return str(cand)
        parent = cur.parent
        if parent == cur:
            return ""
        cur = parent


def _parse_jac_toml_entry_point(jac_toml_path: str) -> str:
    try:
        content = Path(jac_toml_path).read_text(encoding="utf-8")
    except OSError:
        return ""
    quoted = re.search(r'entry[-_]point\s*=\s*["\']([^"\']+)["\']', content)
    if quoted:
        return quoted.group(1)
    bare = re.search(r"entry[-_]point\s*=\s*(\S+)", content)
    if bare:
        return bare.group(1).strip("\"'")
    return ""


def _find_jackal_config(cwd: str) -> str:
    cur = Path(cwd).resolve()
    while True:
        cand = cur / ".jackal"
        if cand.is_file():
            return str(cand)
        parent = cur.parent
        if parent == cur:
            return ""
        cur = parent


def _load_project_config(config_path: str) -> dict:
    if not config_path:
        return {}
    try:
        parsed = json.loads(Path(config_path).read_text(encoding="utf-8"))
        if isinstance(parsed, dict):
            return parsed
    except (OSError, json.JSONDecodeError):
        return {}
    return {}


def _format_project_config(cfg: dict, config_path: str) -> str:
    label = config_path if config_path else "(no .jackal file — using defaults)"
    lines = [
        f"config: {label}",
        f"  autocheck: {cfg.get('autocheck', False)}",
        f"  autoformat: {cfg.get('autoformat', False)}",
        f"  verbose: {cfg.get('verbose', False)}",
        f"  plan: {cfg.get('plan', False)}",
        f"  maxFixAttempts: {cfg.get('maxFixAttempts', 3)}",
        f"  mermaid: {cfg.get('mermaid', False)}",
        f"  notify: {cfg.get('notify', False)}",
        f"  subagents: {cfg.get('subagents', False)}",
    ]
    return "\n".join(lines)


def _walk_jac_files(cwd: str) -> list:
    project_root = Path(cwd).resolve()
    jac_files = []
    stack = [(project_root, 0)]

    while stack:
        dir_path, depth = stack.pop()
        if depth > 8 or len(jac_files) > 500:
            continue
        try:
            entries = sorted(dir_path.iterdir(), key=lambda p: p.name)
        except OSError:
            continue
        for entry in entries:
            if entry.name.startswith(".") and entry.name != ".":
                continue
            if entry.name in _SKIP_DIRS:
                continue
            if entry.is_dir():
                stack.append((entry, depth + 1))
                continue
            if entry.suffix == ".jac":
                rel = str(entry.relative_to(project_root)).replace("\\", "/")
                jac_files.append(rel)

    jac_files.sort()
    return jac_files


def _probe_jac_mcp(jac_binary: str) -> dict:
    try:
        subprocess.run(
            [jac_binary, "mcp", "--inspect"],
            capture_output=True,
            text=True,
            timeout=8,
        )
        return {"available": True, "detail": "jac mcp: available"}
    except (subprocess.TimeoutExpired, OSError):
        return {
            "available": False,
            "detail": "jac mcp: NOT available — `jac mcp` failed. Update jaclang.",
        }


def run_jac_doctor(cwd: str) -> dict:
    jac_binary = find_jac_binary()
    jac_version = ""
    mcp_available = False
    mcp_detail = "jac mcp: NOT checked (no jac binary)"

    jac_toml_path = _find_jac_toml(cwd)
    jac_toml_entry = _parse_jac_toml_entry_point(jac_toml_path) if jac_toml_path else ""
    jackal_config_path = _find_jackal_config(cwd)
    project_config = _load_project_config(jackal_config_path)
    jac_files = _walk_jac_files(cwd)

    if jac_binary:
        try:
            ver = subprocess.run(
                [jac_binary, "--version"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            jac_version = (ver.stdout or "").strip()
        except (subprocess.TimeoutExpired, OSError):
            jac_version = ""
        mcp = _probe_jac_mcp(jac_binary)
        mcp_available = mcp["available"]
        mcp_detail = mcp["detail"]

    lines = []
    if jac_binary:
        lines.append(f"jac binary: {jac_binary}")
        if jac_version:
            lines.append(f"jac version: {jac_version}")
    else:
        lines.append("jac: NOT FOUND (install with: pip install jaclang)")
    lines.append(mcp_detail)

    if jac_toml_path:
        rel = str(Path(jac_toml_path).resolve().relative_to(Path(cwd).resolve()))
        lines.append(f"jac.toml: {rel.replace(chr(92), '/')}")
        if jac_toml_entry:
            lines.append(f"entry_point: {jac_toml_entry}")
    else:
        lines.append("jac.toml: not found")

    lines.append("")
    lines.append(_format_project_config(project_config, jackal_config_path))

    if jac_files:
        lines.append(f"\n.jac files found: {len(jac_files)}")
        for f in jac_files[:20]:
            lines.append(f"  {f}")
        if len(jac_files) > 20:
            lines.append(f"  ... and {len(jac_files) - 20} more")
    else:
        lines.append("\nNo .jac files found in project.")

    return {
        "jacBinary": jac_binary or None,
        "jacVersion": jac_version or None,
        "mcpAvailable": mcp_available,
        "mcpDetail": mcp_detail,
        "jacTomlPath": jac_toml_path or None,
        "jacTomlEntryPoint": jac_toml_entry or None,
        "jackalConfigPath": jackal_config_path or None,
        "projectConfig": project_config,
        "jacFiles": jac_files,
        "summary": "\n".join(lines),
    }
