"""Chain workflow catalog for the all-Jac harness (ported from
lib/jac/orchestration/_chains_toolchain.py -- the Python source of truth,
which itself ports src/orchestration/chains.ts).

Chain .chain.md files define multi-step agent workflows: YAML-like
frontmatter (required name + description) plus one `## <agent>` section
per step. Each step body starts with optional `key: value` config lines
(supported: output, reads as comma list, model) separated from the task
text by the first blank line.

Behavior carried over 1:1:
- Recursive .chain.md discovery sorted by path.
- parse_chain_markdown raises ValueError for missing name/description or
  zero `##` steps; directory loads skip invalid files silently.
- Discovery roots: builtin <root>/chains plus project <cwd>/chains --
  later root wins name collisions on merge; dict preserves insertion
  order (package entries first).
- Catalog formatting ("scout → planner → worker" step summary) and
  chain_dirs_exist probing.

Not ported (execution-loop concerns): chain running/stepping, variable
substitution at run time, LLM wiring. This module is catalog + parsing
only.

Deviations from the Python toolchain:
- Frontmatter helpers are imported from app/agent/subagents.jac (same
  hand-rolled stdlib semantics as _frontmatter_toolchain.py).
- resolve_jackal_root delegates to subagents.resolve_jackal_root, so with
  no agent_dir it tries JACKAL_AGENT_DIR, then JACKAL_ROOT, then cwd;
  callers loading real catalogs pass agent_dir explicitly.
- The `## heading` scan matches line-by-line (r"^##\s+(.+?)\s*$" per
  line) instead of a MULTILINE regex over the whole body; semantics are
  identical.
"""

import os;
import re;
import from .subagents {
    resolve_jackal_root,
    frontmatter_string,
    parse_frontmatter,
    _abs_path,
}


# ============================ chain discovery ============================


"""Recursively list .chain.md files under *dir_path*, sorted by path."""
def list_chain_files(dir_path: str) -> list[str] {
    found: list[str] = [];
    if not os.path.isdir(dir_path) {
        return found;
    }
    try {
        names = sorted(os.listdir(dir_path));
    } except OSError {
        return found;
    }
    dirs: list[str] = [];
    files: list[str] = [];
    for name in names {
        full = os.path.join(dir_path, name);
        if os.path.isdir(full) {
            dirs.append(full);
        } elif os.path.isfile(full) and name.endswith(".chain.md") {
            files.append(full);
        }
    }
    found.extend(files);
    for sub in dirs {
        found.extend(list_chain_files(sub));
    }
    return found;
}


# ============================= step parsing ==============================


"""Parse one step's config lines + task text.

Returns {"agent": ..., "task": ...} plus "output"/"reads"/"model" keys
only when present in the config block before the first blank line."""
def parse_step_body(agent: str, section_body: str) -> dict {
    lines = section_body.split("\n");
    blank_index = -1;
    idx = 0;
    for line in lines {
        if line.strip() == "" {
            blank_index = idx;
            break;
        }
        idx += 1;
    }
    if blank_index == -1 {
        config_lines = lines;
        task = "";
    } else {
        config_lines = lines[:blank_index];
        task = "\n".join(lines[blank_index + 1:]).strip();
    }

    step: dict = {"agent": agent, "task": task};
    for line in config_lines {
        found = re.match(r"^([\w-]+):\s*(.*)$", line);
        if not found {
            continue;
        }
        key = str(found.group(1)).strip().lower();
        raw_value = str(found.group(2)).strip();
        if key == "output" and raw_value {
            step["output"] = raw_value;
            continue;
        }
        if key == "reads" and raw_value {
            reads: list[str] = [];
            for p in raw_value.split(",") {
                piece = p.strip();
                if piece {
                    reads.append(piece);
                }
            }
            step["reads"] = reads;
            continue;
        }
        if key == "model" and raw_value {
            step["model"] = raw_value;
        }
    }
    return step;
}


# ========================== chain markdown parse =========================


"""Parse a chain .chain.md file into a ChainDefinition dict.

Raises ValueError when frontmatter lacks name/description or no `##`
step sections exist."""
def parse_chain_markdown(content: str, source: str, file_path: str) -> dict {
    (fm, body) = parse_frontmatter(content);
    raw_name = frontmatter_string(fm.get("name"));
    name = (raw_name or "").strip();
    raw_desc = frontmatter_string(fm.get("description"));
    description = (raw_desc or "").strip();

    if not name or not description {
        raise ValueError(
            "Chain frontmatter must include name and description (" + file_path + ")"
        );
    }

    # Find all ## heading sections, line by line (see docstring note).
    steps: list[dict] = [];
    current_agent = "";
    section_lines: list[str] = [];
    for line in body.split("\n") {
        heading = re.match(r"^##\s+(.+?)\s*$", line);
        if heading is not None {
            if current_agent {
                section_body = "\n".join(section_lines).rstrip();
                steps.append(parse_step_body(current_agent, section_body));
            }
            current_agent = str(heading.group(1)).strip();
            section_lines = [];
        } elif current_agent {
            section_lines.append(line);
        }
    }
    if current_agent {
        tail_body = "\n".join(section_lines).rstrip();
        steps.append(parse_step_body(current_agent, tail_body));
    }

    if not steps {
        raise ValueError("Chain '" + name + "' has no ## steps (" + file_path + ")");
    }

    return {
        "name": name,
        "description": description,
        "steps": steps,
        "source": source,
        "filePath": file_path,
    };
}


# ================================ loading ================================


"""Load all valid chain definitions from *dir_path* (invalid skipped)."""
def load_chains_from_dir(dir_path: str, source: str) -> list[dict] {
    chains: list[dict] = [];
    for file_path in list_chain_files(dir_path) {
        try {
            fh = open(file_path, encoding="utf-8");
            try {
                content = fh.read();
            } finally {
                fh.close();
            }
            chains.append(parse_chain_markdown(content, source, file_path));
        } except Exception {
            # skip invalid chain files
        }
    }
    return chains;
}


"""Discovery roots: {"packageDir": <root>/chains, "projectDir": <cwd>/chains}."""
def discover_chain_dirs(cwd: str, agent_dir: str = "") -> dict {
    base_root = agent_dir if agent_dir else resolve_jackal_root();
    return {
        "packageDir": os.path.join(base_root, "chains"),
        "projectDir": os.path.join(_abs_path(cwd), "chains"),
    };
}


"""Merged chain map keyed by name (project overrides package)."""
def load_chains(cwd: str, agent_dir: str = "") -> dict {
    dirs = discover_chain_dirs(cwd, agent_dir);
    merged: dict = {};
    for chain in load_chains_from_dir(str(dirs["packageDir"]), "package") {
        merged[str(chain["name"])] = chain;
    }
    for chain in load_chains_from_dir(str(dirs["projectDir"]), "project") {
        merged[str(chain["name"])] = chain;
    }
    return merged;
}


def _chain_sort_key(chain: dict) -> str {
    return str(chain.get("name", ""));
}


"""Name-sorted list of merged chain definitions."""
def list_chains(cwd: str, agent_dir: str = "") -> list[dict] {
    chains: list[dict] = list(load_chains(cwd, agent_dir).values());
    return sorted(chains, key=_chain_sort_key);
}


"""Look up one merged chain by name; None when unknown."""
def get_chain(cwd: str, name: str, agent_dir: str = "") -> dict | None {
    return load_chains(cwd, agent_dir).get(name.strip());
}


# ============================ catalog display ============================


"""Human-readable chain catalog ('No chains found.' when empty)."""
def format_chain_catalog(cwd: str, agent_dir: str = "") -> str {
    chains = list_chains(cwd, agent_dir);
    if not chains {
        return "No chains found.";
    }
    lines: list[str] = ["Available chains:", ""];
    for chain in chains {
        agents_seq: list[str] = [];
        steps: any = chain["steps"];
        for step in steps {
            step_dict: dict = step;
            agents_seq.append(str(step_dict.get("agent", "")));
        }
        lines.append(
            "- " + str(chain["name"]) + " (" + str(chain["source"]) + ") — "
            + str(chain["description"])
        );
        lines.append("  steps: " + " → ".join(agents_seq));
    }
    return "\n".join(lines);
}


"""True when either discovery root exists as a directory."""
def chain_dirs_exist(cwd: str, agent_dir: str = "") -> bool {
    dirs = discover_chain_dirs(cwd, agent_dir);
    return os.path.isdir(str(dirs["packageDir"])) or os.path.isdir(str(dirs["projectDir"]));
}
