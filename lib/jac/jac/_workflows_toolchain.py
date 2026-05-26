"""Jackal Jac workflows — prompt templates and skill loading (Phase 1 toolchain)."""

from __future__ import annotations

import os
import re
from pathlib import Path


def _parse_frontmatter(content: str) -> tuple[dict, str]:
    frontmatter: dict = {}
    normalized = content.replace("\r\n", "\n")
    if not normalized.startswith("---"):
        return frontmatter, normalized
    end_index = normalized.find("\n---", 3)
    if end_index == -1:
        return frontmatter, normalized
    block = normalized[4:end_index]
    body = normalized[end_index + 4 :].strip()
    current_key: str | None = None
    list_items: list[str] = []

    def flush_list() -> None:
        nonlocal current_key, list_items
        if current_key and list_items:
            frontmatter[current_key] = list(list_items)
        list_items = []
        current_key = None

    for raw_line in block.split("\n"):
        line = raw_line.rstrip()
        list_match = re.match(r"^\s*-\s+(.*)$", line)
        if list_match and current_key:
            list_items.append(list_match.group(1).strip().strip("'\""))
            continue
        flush_list()
        match = re.match(r"^([\w-]+):\s*(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2) or ""
        if not value.strip():
            current_key = key
            continue
        trimmed = value.strip()
        if (trimmed.startswith('"') and trimmed.endswith('"')) or (
            trimmed.startswith("'") and trimmed.endswith("'")
        ):
            frontmatter[key] = trimmed[1:-1]
        else:
            frontmatter[key] = trimmed
    flush_list()
    return frontmatter, body


def resolve_package_root(explicit: str | None = None) -> str:
    if explicit and Path(explicit).is_dir():
        return str(Path(explicit).resolve())
    env = os.environ.get("JACKAL_AGENT_DIR") or os.environ.get("JACKAL_ROOT")
    if env:
        root = Path(env).resolve()
        if (root / "pi" / "skills").is_dir():
            return str(root)
    # lib/jac/jac -> repo root
    here = Path(__file__).resolve().parent
    for candidate in (here.parent.parent.parent, here.parent.parent):
        if (candidate / "pi" / "skills").is_dir():
            return str(candidate)
    return str(here.parent.parent.parent)


def load_skill_content(skill_dir_name: str, package_root: str | None = None) -> str:
    root = resolve_package_root(package_root)
    path = Path(root) / "pi" / "skills" / skill_dir_name / "SKILL.md"
    if not path.is_file():
        return ""
    try:
        text = path.read_text(encoding="utf-8")
        _, body = _parse_frontmatter(text)
        return body.strip()
    except OSError:
        return ""


def render_prompt_template(
    name: str, vars: dict[str, str], package_root: str | None = None
) -> str:
    root = resolve_package_root(package_root)
    path = Path(root) / "pi" / "prompts" / f"{name}.md"
    if not path.is_file():
        raise FileNotFoundError(f"Prompt template not found: pi/prompts/{name}.md")
    text = path.read_text(encoding="utf-8")
    for key, value in vars.items():
        text = text.replace(f"{{{{{key}}}}}", value)
    return text.strip()


def build_osp_prompt(description: str, package_root: str | None = None) -> str:
    osp_skill = load_skill_content("osp-skill", package_root)
    fallback = (
        "(osp-skill unavailable — use Jac MCP list_examples/get_example/search_docs)"
    )
    return render_prompt_template(
        "osp",
        {
            "description": description.strip(),
            "osp_skill": osp_skill or fallback,
        },
        package_root,
    )


def build_convert_python_prompt(python_path: str, package_root: str | None = None) -> str:
    return render_prompt_template(
        "convert-python", {"path": python_path.strip()}, package_root
    )


def build_idiom_review_prompt(paths: list[str], package_root: str | None = None) -> str:
    normalized = [p.strip() for p in paths if p.strip()]
    file_list = (
        "\n".join(f"- `{p}`" for p in normalized)
        if normalized
        else "- (scan all `.jac` files in the project)"
    )
    return render_prompt_template(
        "review-idioms",
        {
            "paths": ", ".join(normalized) if normalized else "(project-wide)",
            "file_list": file_list,
        },
        package_root,
    )


def build_explain_prompt(
    mode: str, args: str, package_root: str | None = None
) -> str:
    trimmed = args.strip()
    if mode == "walker":
        return render_prompt_template(
            "explain-walker",
            {"code": trimmed or "(provide walker code after the command)"},
            package_root,
        )
    if mode == "error":
        parts = trimmed.split("--ctx")
        error_text = (parts[0] if parts else trimmed).strip()
        ctx = parts[1].strip() if len(parts) > 1 else ""
        context = f"Additional context:\n{ctx}" if ctx else ""
        return render_prompt_template(
            "explain-error",
            {
                "error": error_text or "(paste the error after the command)",
                "context": context,
            },
            package_root,
        )
    if mode == "graph":
        return render_prompt_template(
            "explain-graph",
            {"code": trimmed or "(provide Jac code after the command)"},
            package_root,
        )
    return render_prompt_template(
        "explain",
        {"code": trimmed or "(provide Jac code after the command)"},
        package_root,
    )


def build_diagram_to_model_prompt(
    source: str, content: str, package_root: str | None = None
) -> str:
    return render_prompt_template(
        "diagram-to-model",
        {
            "source": source.strip() or "user description",
            "content": content.strip()
            or "(no additional content — infer from source label)",
        },
        package_root,
    )
