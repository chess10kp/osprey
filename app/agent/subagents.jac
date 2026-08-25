"""Subagent catalog for the all-Jac harness (ported from
lib/jac/orchestration/_subagents_toolchain.py -- the Python source of
truth, which itself ports src/orchestration/subagents.ts).

Behavior carried over 1:1:
- Recursive .md discovery that skips *.chain.md files (those belong to the
  chain catalog), sorted by path for deterministic ordering.
- Agent markdown loading: --- delimited frontmatter with required name +
  description (missing either excludes the file silently), optional tools
  (inline [a, b] or dash-block lists) and model, systemPrompt from the
  stripped body. Records are plain dicts with camelCase keys matching the
  legacy bridge contract (name/description/systemPrompt/tools/model/
  source/filePath).
- Discovery roots: builtin <agent_dir>/.pi/agents plus project <cwd>/
  subagents -- later root wins name collisions on merge.
- Model overrides from settings.json ("subagents.agentOverrides.<name>.
  model") and from the walked-up `.jackal` project config ("subagents"
  section: "model" key becomes "__default__", other string values or
  {model: ...} dicts map agent name -> model).
- Tool normalization: alias table (read_file->read, grep/find/ls/...
  ->bash), mcp:<name> passthrough, always-excluded set
  {agent, subagent, compact_context}, bash re-pin when allowed but
  filtered out, and a fallback to all non-excluded tools when filtering
  yields nothing.
- Human-readable catalog formatting.

Deviations from the Python toolchain:
- Frontmatter parsing is hand-rolled stdlib here (mirrors
  lib/jac/orchestration/_frontmatter_toolchain.py behavior), same as
  app/agent/skills.jac. No PyYAML.
- resolve_jackal_root cannot walk up from __file__ (no stable __file__ in
  compiled Jac modules), so with no agent_dir argument it tries
  JACKAL_AGENT_DIR, then JACKAL_ROOT, then cwd; callers loading real
  catalogs pass agent_dir explicitly.
- Project model overrides reuse load_project_config from app/agent/
  compaction.jac (.jackal walk-up) instead of importing the Python
  toolchain module directly.
"""

import os;
import json;
import re;
import from .compaction { load_project_config }

glob SUBAGENT_TOOL_ALIASES: dict = {
        "read_file": "read",
        "write_file": "write",
        "edit_file": "edit",
        "grep": "bash",
        "find": "bash",
        "ls": "bash",
        "list_directory": "bash",
        "search_file_contents": "bash",
        "find_files": "bash",
    },
     EXCLUDED_SUBAGENT_TOOLS: list[str] = ["agent", "subagent", "compact_context"];


# ============================ path shims =================================


"""str-typed shim over os.path.abspath, which demands PathLike here."""
def _abs_path(p: any) -> str {
    return str(os.path.abspath(p));
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


"""Coerce a frontmatter value to a string list (comma split for scalars)."""
def frontmatter_string_list(value: any) -> list[str] {
    if value is None {
        return [];
    }
    if isinstance(value, list) {
        items: list[str] = [];
        for item in value {
            text = str(item);
            if text {
                items.append(text);
            }
        }
        return items;
    }
    parts: list[str] = [];
    for part in str(value).split(",") {
        piece = part.strip();
        if piece {
            parts.append(piece);
        }
    }
    return parts;
}


# ============================ path helpers ===============================


"""Resolve JACKAL_AGENT_DIR, else JACKAL_ROOT, else cwd (see docstring)."""
def resolve_jackal_root(agent_dir: str = "") -> str {
    if agent_dir {
        return _abs_path(agent_dir);
    }
    env = os.environ.get("JACKAL_AGENT_DIR");
    if env {
        return _abs_path(env);
    }
    root_env = os.environ.get("JACKAL_ROOT");
    if root_env {
        return _abs_path(root_env);
    }
    return _abs_path(os.getcwd());
}


def _is_existing_dir(path: str) -> bool {
    return os.path.isdir(path);
}


def _is_agent_md(name: str) -> bool {
    # Accept .md files that are NOT chain files.
    return name.endswith(".md") and not name.endswith(".chain.md");
}


"""Recursively list files under *directory* accepted by *accept*, sorted.

Returns [] for missing/unreadable directories."""
def _list_files(directory: str, accept: any) -> list[str] {
    found: list[str] = [];
    if not _is_existing_dir(directory) {
        return found;
    }
    try {
        names = sorted(os.listdir(directory));
    } except OSError {
        return found;
    }
    dirs: list[str] = [];
    files: list[str] = [];
    for name in names {
        full = os.path.join(directory, name);
        if os.path.isdir(full) {
            dirs.append(full);
        } elif os.path.isfile(full) and accept(name) {
            files.append(full);
        }
    }
    # Files of this level first, then recurse (depth-first, name-sorted).
    found.extend(files);
    for sub in dirs {
        found.extend(_list_files(sub, accept));
    }
    return found;
}


# ============================= agent loading =============================


"""Load one agent markdown file into a SubagentDefinition-style dict.

Returns None when unreadable or missing name/description frontmatter."""
def load_agent_file(file_path: str, source: str) -> dict | None {
    try {
        fh = open(file_path, encoding="utf-8");
        try {
            raw = fh.read();
        } finally {
            fh.close();
        }
    } except Exception {
        return None;
    }
    (fm, body) = parse_frontmatter(raw);
    raw_name = frontmatter_string(fm.get("name"));
    name = (raw_name or "").strip();
    raw_desc = frontmatter_string(fm.get("description"));
    description = (raw_desc or "").strip();
    if not name or not description {
        return None;
    }
    raw_tools = frontmatter_string_list(fm.get("tools"));
    tools = raw_tools if raw_tools else None;
    raw_model = frontmatter_string(fm.get("model"));
    model = raw_model if raw_model else None;
    return {
        "name": name,
        "description": description,
        "systemPrompt": body.strip(),
        "tools": tools,
        "model": model,
        "source": source,
        "filePath": file_path,
    };
}


"""Load all valid agent definitions found under *directory*."""
def load_agents_from_dir(directory: str, source: str) -> list[dict] {
    agents: list[dict] = [];
    for fp in _list_files(directory, _is_agent_md) {
        agent = load_agent_file(fp, source);
        if agent is not None {
            agents.append(agent);
        }
    }
    return agents;
}


# ============================== discovery ================================


"""Discovery roots: {"packageDir": <root>/.pi/agents,
"projectDir": <cwd>/subagents}."""
def discover_subagent_dirs(cwd: str, agent_dir: str = "") -> dict {
    base_root = resolve_jackal_root(agent_dir);
    return {
        "packageDir": os.path.join(base_root, ".pi", "agents"),
        "projectDir": os.path.join(_abs_path(cwd), "subagents"),
    };
}


"""Merged subagent map keyed by name (project overrides package)."""
def load_subagents(cwd: str, agent_dir: str = "") -> dict {
    dirs = discover_subagent_dirs(cwd, agent_dir);
    merged: dict = {};
    for agent in load_agents_from_dir(str(dirs["packageDir"]), "package") {
        merged[str(agent["name"])] = agent;
    }
    for agent in load_agents_from_dir(str(dirs["projectDir"]), "project") {
        merged[str(agent["name"])] = agent;
    }
    return merged;
}


def _agent_sort_key(agent: dict) -> str {
    return str(agent.get("name", ""));
}


"""Name-sorted list of merged subagent definitions."""
def list_subagents(cwd: str, agent_dir: str = "") -> list[dict] {
    agents: list[dict] = list(load_subagents(cwd, agent_dir).values());
    return sorted(agents, key=_agent_sort_key);
}


"""Look up one merged subagent by name; None when unknown."""
def get_subagent(cwd: str, name: str, agent_dir: str = "") -> dict | None {
    return load_subagents(cwd, agent_dir).get(name.strip());
}


# ============================ model overrides ============================


"""settings.json overrides: {"<agent>": "<model>"}; {} when absent/broken."""
def load_settings_model_overrides(agent_dir: str = "") -> dict {
    settings_path = os.path.join(resolve_jackal_root(agent_dir), "settings.json");
    if not os.path.isfile(settings_path) {
        return {};
    }
    fh = None;
    try {
        fh = open(settings_path, encoding="utf-8");
        parsed = json.load(fh);
    } except Exception {
        return {};
    } finally {
        if fh is not None {
            fh.close();
        }
    }
    if not isinstance(parsed, dict) {
        return {};
    }
    sub: any = parsed.get("subagents");
    if not isinstance(sub, dict) {
        return {};
    }
    overrides: any = sub.get("agentOverrides");
    if not isinstance(overrides, dict) {
        return {};
    }
    out: dict = {};
    for agent_name in overrides {
        value: any = overrides[agent_name];
        if isinstance(value, dict) and isinstance(value.get("model"), str) {
            out[str(agent_name)] = str(value["model"]);
        }
    }
    return out;
}


"""`.jackal` project-config overrides: {"__default__": ...} seed plus
per-agent models from string values or {"model": ...} dicts."""
def load_project_model_overrides(cwd: str) -> dict {
    cfg = load_project_config(cwd);
    sub: any = cfg.get("subagents");
    if not isinstance(sub, dict) {
        return {};
    }
    out: dict = {};
    default_model: any = sub.get("model");
    if isinstance(default_model, str) and default_model.strip() {
        out["__default__"] = default_model.strip();
    }
    for key in sub {
        value: any = sub[key];
        if key in ("model", "enabled") {
            continue;
        }
        if isinstance(value, str) and value.strip() {
            out[str(key)] = value.strip();
        } elif isinstance(value, dict) and isinstance(value.get("model"), str) {
            out[str(key)] = str(value["model"]).strip();
        }
    }
    return out;
}


# =========================== tool normalization ==========================


"""Normalize an allowed-tool list into a set (aliases + mcp: prefix).

None means "all allowed" (empty or missing input)."""
def normalize_allowed_tool_names(tools: list | None) -> set | None {
    if not tools {
        return None;
    }
    allowed: set = set();
    for raw in tools {
        name = str(raw).strip();
        if not name {
            continue;
        }
        if name.startswith("mcp:") {
            allowed.add(name[4:]);
            continue;
        }
        aliased: any = SUBAGENT_TOOL_ALIASES.get(name);
        allowed.add(str(aliased) if aliased is not None else name);
    }
    return allowed;
}


"""Filter *all_tool_names* for subagent use.

Always drops EXCLUDED_SUBAGENT_TOOLS, intersects allowed_names when given,
re-pins bash when it was allowed but filtered away, and falls back to all
non-excluded tools when nothing survives."""
def filter_tools_for_subagent(all_tool_names: list, allowed_names: set | None) -> list[str] {
    excluded: set = set(EXCLUDED_SUBAGENT_TOOLS);
    filtered: list[str] = [];
    for t in all_tool_names {
        name = str(t);
        if name in excluded {
            continue;
        }
        if allowed_names is not None and name not in allowed_names {
            continue;
        }
        filtered.append(name);
    }
    if allowed_names and "bash" in allowed_names and "bash" not in filtered {
        if "bash" in all_tool_names {
            filtered.append("bash");
        }
    }
    if filtered {
        return filtered;
    }
    fallback: list[str] = [];
    for t in all_tool_names {
        name = str(t);
        if name not in excluded {
            fallback.append(name);
        }
    }
    return fallback;
}


# ============================ catalog display ============================


"""Human-readable catalog of merged subagents ('No subagents found.' empty)."""
def format_subagent_catalog(cwd: str, agent_dir: str = "") -> str {
    agents = list_subagents(cwd, agent_dir);
    if not agents {
        return "No subagents found.";
    }
    lines: list[str] = ["Available subagents:", ""];
    for agent in agents {
        raw_tools: any = agent.get("tools");
        tool_count: any = len(raw_tools) if isinstance(raw_tools, list) else "all";
        model = str(agent.get("model") or "inherit");
        lines.append(
            "- " + str(agent["name"]) + " (" + str(agent["source"]) + ") — "
            + str(agent["description"])
        );
        lines.append("  tools: " + str(tool_count) + "  model: " + model);
    }
    return "\n".join(lines);
}
