"""Chain workflow discovery, loading, and parsing.

Ports src/orchestration/chains.ts to Python toolchain.
Chain .chain.md files define multi-step agent workflows with frontmatter metadata
and ## step sections specifying agent, task, output, reads, and model overrides.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

from _frontmatter_toolchain import (
    frontmatter_string as _fm_string,
    parse_frontmatter as _parse_frontmatter,
)


# ---------------------------------------------------------------------------
# Helpers shared with subagents (duplicated here until a shared util module exists)
# ---------------------------------------------------------------------------

def resolve_jackal_root() -> str:
    """Resolve the Jackal package root (JACKAL_AGENT_DIR or repo root)."""
    env = os.environ.get("JACKAL_AGENT_DIR")
    if env:
        return os.path.abspath(env)
    # Walk up from this file to the repo root (lib/jac/orchestration/ -> repo)
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


def is_existing_dir(path: str) -> bool:
    """Check if a path exists and is a directory."""
    try:
        return os.path.isdir(path)
    except OSError:
        return False


# ---------------------------------------------------------------------------
# Chain file discovery
# ---------------------------------------------------------------------------

def list_chain_files(dir_path: str) -> list[str]:
    """Recursively list all .chain.md files under *dir_path*, sorted by name."""
    if not os.path.isdir(dir_path):
        return []
    out: list[str] = []
    for root, _dirs, files in os.walk(dir_path):
        for name in sorted(files):
            if name.endswith(".chain.md"):
                out.append(os.path.join(root, name))
    return out


# ---------------------------------------------------------------------------
# Step parsing
# ---------------------------------------------------------------------------

def parse_step_body(agent: str, section_body: str) -> dict[str, Any]:
    """Parse a chain step's config lines + task text.

    Returns a dict with keys: agent, task, output (str|None), reads (list|None), model (str|None).
    """
    lines = section_body.split("\n")
    blank_index = -1
    for i, line in enumerate(lines):
        if line.strip() == "":
            blank_index = i
            break

    if blank_index == -1:
        config_lines = lines
        task = ""
    else:
        config_lines = lines[:blank_index]
        task = "\n".join(lines[blank_index + 1:]).strip()

    step: dict[str, Any] = {"agent": agent, "task": task}

    for line in config_lines:
        match = re.match(r"^([\w-]+):\s*(.*)$", line, re.IGNORECASE)
        if not match:
            continue
        key = match.group(1).strip().lower()
        raw_value = match.group(2).strip()

        if key == "output" and raw_value:
            step["output"] = raw_value
            continue
        if key == "reads" and raw_value:
            step["reads"] = [p.strip() for p in raw_value.split(",") if p.strip()]
            continue
        if key == "model" and raw_value:
            step["model"] = raw_value

    return step


# ---------------------------------------------------------------------------
# Chain markdown parsing
# ---------------------------------------------------------------------------

def parse_chain_markdown(
    content: str,
    source: str,
    file_path: str,
) -> dict[str, Any]:
    """Parse a chain .chain.md file into a ChainDefinition dict.

    Raises ValueError if frontmatter is missing name/description or no steps found.
    """
    parsed = _parse_frontmatter(content)
    fm = parsed.frontmatter
    body = parsed.body

    name = (_fm_string(fm.get("name")) or "").strip()
    description = (_fm_string(fm.get("description")) or "").strip()

    if not name or not description:
        raise ValueError(
            f"Chain frontmatter must include name and description ({file_path})"
        )

    # Find all ## heading sections
    pattern = re.compile(r"^##\s+(.+)[^\S\n]*$", re.MULTILINE)
    matches = list(pattern.finditer(body))

    steps: list[dict[str, Any]] = []
    for i, match in enumerate(matches):
        agent = match.group(1).strip()
        # Section body starts after the heading line (skip optional newline)
        section_start = match.end()
        if section_start < len(body) and body[section_start] == "\n":
            section_start += 1
        section_end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
        section_body = body[section_start:section_end].rstrip()
        steps.append(parse_step_body(agent, section_body))

    if not steps:
        raise ValueError(f"Chain '{name}' has no ## steps ({file_path})")

    return {
        "name": name,
        "description": description,
        "steps": steps,
        "source": source,
        "filePath": file_path,
    }


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def _load_chains_from_dir(dir_path: str, source: str) -> list[dict[str, Any]]:
    """Load all chain definitions from a directory."""
    chains: list[dict[str, Any]] = []
    for file_path in list_chain_files(dir_path):
        try:
            content = Path(file_path).read_text(encoding="utf-8")
            chains.append(parse_chain_markdown(content, source, file_path))
        except Exception:
            # skip invalid chain files
            pass
    return chains


def discover_chain_dirs(cwd: str, agent_dir: str | None = None) -> dict[str, str]:
    """Find package and project chain directories.

    Returns dict with 'packageDir' and 'projectDir' keys.
    """
    root = (agent_dir or resolve_jackal_root())
    return {
        "packageDir": os.path.join(root, "chains"),
        "projectDir": os.path.join(os.path.abspath(cwd), "chains"),
    }


def load_chains(cwd: str, agent_dir: str | None = None) -> dict[str, dict[str, Any]]:
    """Load all chains, merging package and project (project overrides package).

    Returns an ordered dict of chain name → ChainDefinition.
    """
    dirs = discover_chain_dirs(cwd, agent_dir)
    merged: dict[str, dict[str, Any]] = {}

    for chain in _load_chains_from_dir(dirs["packageDir"], "package"):
        merged[chain["name"]] = chain
    for chain in _load_chains_from_dir(dirs["projectDir"], "project"):
        merged[chain["name"]] = chain

    return merged


def list_chains(cwd: str, agent_dir: str | None = None) -> list[dict[str, Any]]:
    """Return chains sorted by name."""
    chains = load_chains(cwd, agent_dir)
    return sorted(chains.values(), key=lambda c: c["name"])


def get_chain(cwd: str, name: str, agent_dir: str | None = None) -> dict[str, Any] | None:
    """Look up a chain by name."""
    return load_chains(cwd, agent_dir).get(name.strip())


# ---------------------------------------------------------------------------
# Catalog formatting
# ---------------------------------------------------------------------------

def format_chain_catalog(cwd: str, agent_dir: str | None = None) -> str:
    """Format the chain catalog as a human-readable string."""
    chains = list_chains(cwd, agent_dir)
    if not chains:
        return "No chains found."

    lines = ["Available chains:", ""]
    for chain in chains:
        agents = " → ".join(step["agent"] for step in chain["steps"])
        lines.append(f"- {chain['name']} ({chain['source']}) — {chain['description']}")
        lines.append(f"  steps: {agents}")
    return "\n".join(lines)


def chain_dirs_exist(cwd: str, agent_dir: str | None = None) -> bool:
    """Check if any chain directories exist."""
    dirs = discover_chain_dirs(cwd, agent_dir)
    return is_existing_dir(dirs["packageDir"]) or is_existing_dir(dirs["projectDir"])
