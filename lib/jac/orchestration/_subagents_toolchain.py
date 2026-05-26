"""Subagent catalog — discovery, loading, tool normalization, model overrides."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Callable

from _frontmatter_toolchain import (
    frontmatter_string as _fm_string,
    frontmatter_string_list as _fm_string_list,
    parse_frontmatter as _parse_frontmatter,
)


# ── Constants ────────────────────────────────────────────────────────────────

SUBAGENT_TOOL_ALIASES: dict[str, str] = {
    "read_file": "read",
    "write_file": "write",
    "edit_file": "edit",
    "grep": "bash",
    "find": "bash",
    "ls": "bash",
    "list_directory": "bash",
    "search_file_contents": "bash",
    "find_files": "bash",
}

EXCLUDED_SUBAGENT_TOOLS: frozenset[str] = frozenset(
    ["agent", "subagent", "compact_context"]
)


# ── Path helpers ─────────────────────────────────────────────────────────────


def resolve_jackal_root(agent_dir: str | None = None) -> str:
    """Resolve JACKAL_AGENT_DIR or compute a default relative to this file."""
    if agent_dir:
        return os.path.abspath(agent_dir)
    env = os.environ.get("JACKAL_AGENT_DIR")
    if env:
        return os.path.abspath(env)
    # Default: repo root (lib/jac/orchestration → ../../..)
    return os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", "..")
    )


def is_existing_dir(path: str) -> bool:
    """Check if *path* is an existing directory."""
    try:
        return Path(path).is_dir()
    except OSError:
        return False


# ── File discovery ───────────────────────────────────────────────────────────


def list_markdown_files(
    directory: str,
    predicate_fn: Callable[[str], bool] | None = None,
) -> list[str]:
    """Recursively list files under *directory* accepted by *predicate_fn*.

    If *predicate_fn* is ``None``, accepts all ``.md`` files.
    """
    if not is_existing_dir(directory):
        return []

    if predicate_fn is None:
        predicate_fn = lambda _name: True  # noqa: E731

    results: list[str] = []

    def _walk(current: str) -> None:
        try:
            entries = sorted(Path(current).iterdir(), key=lambda e: e.name)
        except OSError:
            return

        for entry in entries:
            if entry.is_dir():
                _walk(str(entry))
            elif entry.is_file() and predicate_fn(entry.name):
                results.append(str(entry))

    _walk(directory)
    return results


# ── Agent loading ────────────────────────────────────────────────────────────


def load_agent_file(file_path: str, source: str) -> dict | None:
    """Load a single agent markdown file.

    Returns a SubagentDefinition-style dict or ``None`` on parse failure.
    """
    try:
        content = Path(file_path).read_text(encoding="utf-8")
    except OSError:
        return None

    parsed = _parse_frontmatter(content)
    fm = parsed.frontmatter

    name = (_fm_string(fm.get("name")) or "").strip()
    description = (_fm_string(fm.get("description")) or "").strip()
    if not name or not description:
        return None

    raw_tools = _fm_string_list(fm.get("tools"))
    tools = raw_tools if raw_tools else None

    model_val = _fm_string(fm.get("model"))

    return {
        "name": name,
        "description": description,
        "systemPrompt": parsed.body.strip(),
        "tools": tools,
        "model": model_val if model_val else None,
        "source": source,
        "filePath": file_path,
    }


def _is_agent_md(name: str) -> bool:
    """Accept .md files that are NOT chain files."""
    return name.endswith(".md") and not name.endswith(".chain.md")


def load_agents_from_dir(directory: str, source: str) -> list[dict]:
    """Load all agent definitions found in *directory*."""
    files = list_markdown_files(directory, _is_agent_md)
    agents: list[dict] = []
    for fp in files:
        agent = load_agent_file(fp, source)
        if agent is not None:
            agents.append(agent)
    return agents


# ── Discovery ────────────────────────────────────────────────────────────────


def discover_subagent_dirs(
    cwd: str,
    agent_dir: str | None = None,
) -> dict[str, str]:
    """Return ``{"packageDir": ..., "projectDir": ...}``."""
    root = resolve_jackal_root(agent_dir)
    return {
        "packageDir": os.path.join(root, ".pi", "agents"),
        "projectDir": os.path.join(os.path.abspath(cwd), "subagents"),
    }


def load_subagents(
    cwd: str,
    agent_dir: str | None = None,
) -> dict[str, dict]:
    """Load merged subagent map (project overrides package)."""
    dirs = discover_subagent_dirs(cwd, agent_dir)
    merged: dict[str, dict] = {}

    for agent in load_agents_from_dir(dirs["packageDir"], "package"):
        merged[agent["name"]] = agent
    for agent in load_agents_from_dir(dirs["projectDir"], "project"):
        merged[agent["name"]] = agent

    return merged


def list_subagents(
    cwd: str,
    agent_dir: str | None = None,
) -> list[dict]:
    """Sorted list of subagent definitions."""
    agents = list(load_subagents(cwd, agent_dir).values())
    agents.sort(key=lambda a: a["name"])
    return agents


def get_subagent(
    cwd: str,
    name: str,
    agent_dir: str | None = None,
) -> dict | None:
    """Look up a subagent by name."""
    return load_subagents(cwd, agent_dir).get(name.strip())


# ── Model overrides ──────────────────────────────────────────────────────────


def load_settings_model_overrides(
    agent_dir: str | None = None,
) -> dict[str, str]:
    """Load ``settings.json`` subagent model overrides."""
    settings_path = os.path.join(resolve_jackal_root(agent_dir), "settings.json")
    if not os.path.isfile(settings_path):
        return {}

    try:
        with open(settings_path, encoding="utf-8") as f:
            parsed = json.load(f)
        overrides = (
            parsed.get("subagents", {}).get("agentOverrides", {})
        )
        out: dict[str, str] = {}
        for agent_name, value in overrides.items():
            if isinstance(value, dict) and isinstance(value.get("model"), str):
                out[agent_name] = value["model"]
        return out
    except (OSError, json.JSONDecodeError, TypeError):
        return {}


def load_project_model_overrides(cwd: str) -> dict[str, str]:
    """Load model overrides from ``.jackal`` project config.

    Delegates to ``_project_config_toolchain.load_project_config``.
    """
    # Local import to avoid circulars at module scope — the config module
    # lives in a sibling package already on sys.path via toolchain_stdio.
    from _project_config_toolchain import load_project_config as _load_config  # noqa: WPS433

    cfg = _load_config(cwd)
    sub = cfg.get("subagents")
    if not sub or not isinstance(sub, dict):
        return {}

    out: dict[str, str] = {}
    default_model = sub.get("model")
    if isinstance(default_model, str) and default_model.strip():
        out["__default__"] = default_model.strip()

    for key, value in sub.items():
        if key in ("model", "enabled"):
            continue
        if isinstance(value, str) and value.strip():
            out[key] = value.strip()
        elif isinstance(value, dict) and isinstance(value.get("model"), str):
            out[key] = value["model"].strip()

    return out


# ── Tool normalization ──────────────────────────────────────────────────────


def normalize_allowed_tool_names(
    tools: list[str] | None,
) -> set[str] | None:
    """Normalize a tool name list into a set, applying aliases.

    Returns ``None`` when *tools* is empty / ``None`` (meaning "all allowed").
    """
    if not tools:
        return None

    allowed: set[str] = set()
    for raw in tools:
        name = raw.strip()
        if not name:
            continue
        if name.startswith("mcp:"):
            allowed.add(name[4:])
            continue
        allowed.add(SUBAGENT_TOOL_ALIASES.get(name, name))
    return allowed


def filter_tools_for_subagent(
    all_tool_names: list[str],
    allowed_names: set[str] | None,
) -> list[str]:
    """Filter *all_tool_names* for subagent use.

    Always excludes :data:`EXCLUDED_SUBAGENT_TOOLS`.  Falls back to all
    non-excluded tools when the result would otherwise be empty.
    """
    filtered = [
        t
        for t in all_tool_names
        if t not in EXCLUDED_SUBAGENT_TOOLS
        and (allowed_names is None or t in allowed_names)
    ]

    # If bash is allowed but somehow missing, ensure it's present
    if allowed_names and "bash" in allowed_names and "bash" not in filtered:
        if "bash" in all_tool_names:
            filtered.append("bash")

    if filtered:
        return filtered

    # Fallback: everything except excluded
    return [t for t in all_tool_names if t not in EXCLUDED_SUBAGENT_TOOLS]


# ── Catalog formatting ──────────────────────────────────────────────────────


def format_subagent_catalog(
    cwd: str,
    agent_dir: str | None = None,
) -> str:
    """Human-readable catalog of available subagents."""
    agents = list_subagents(cwd, agent_dir)
    if not agents:
        return "No subagents found."

    lines = ["Available subagents:", ""]
    for agent in agents:
        tool_count = len(agent["tools"]) if agent.get("tools") else "all"
        model = agent.get("model") or "inherit"
        lines.append(f"- {agent['name']} ({agent['source']}) — {agent['description']}")
        lines.append(f"  tools: {tool_count}  model: {model}")
    return "\n".join(lines)
