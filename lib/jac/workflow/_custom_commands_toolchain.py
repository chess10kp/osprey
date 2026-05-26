"""Custom commands — load and expand .jackal/commands/*.md."""

from __future__ import annotations

import os
import re
from pathlib import Path

from _frontmatter_toolchain import (
    frontmatter_string,
    frontmatter_string_list,
    parse_frontmatter,
)


def _find_commands_root(cwd: str) -> str | None:
    cur = Path(cwd).resolve()
    while True:
        candidate = cur / ".jackal" / "commands"
        if candidate.is_dir():
            return str(candidate)
        parent = cur.parent
        if parent == cur:
            return None
        cur = parent


def _command_name_from_path(commands_root: str, file_path: str) -> str:
    rel = os.path.relpath(file_path, commands_root).replace("\\", "/")
    without_ext = re.sub(r"\.md$", "", rel, flags=re.IGNORECASE)
    parts = without_ext.split("/")
    if len(parts) == 1:
        return parts[0]
    return ":".join(parts[:-1]) + ":" + parts[-1]


def _list_command_files(dir_path: str) -> list[str]:
    out: list[str] = []

    def walk(current: str) -> None:
        try:
            entries = sorted(os.scandir(current), key=lambda e: e.name)
        except OSError:
            return

        for entry in entries:
            fp = os.path.join(current, entry.name)
            if entry.is_dir():
                if entry.name == "resources":
                    continue
                walk(fp)
                continue
            if entry.is_file() and entry.name.endswith(".md"):
                out.append(fp)

    walk(dir_path)
    return out


def _load_command_file(commands_root: str, file_path: str) -> dict | None:
    try:
        content = Path(file_path).read_text(encoding="utf-8")
    except OSError:
        return None

    parsed = parse_frontmatter(content)
    name = _command_name_from_path(commands_root, file_path)
    description = (frontmatter_string(parsed.frontmatter.get("description")) or name).strip()

    return {
        "name": name,
        "description": description,
        "aliases": frontmatter_string_list(parsed.frontmatter.get("aliases")),
        "parameters": frontmatter_string_list(parsed.frontmatter.get("parameters")),
        "body": parsed.body.strip(),
        "filePath": file_path,
    }


def load_custom_commands(cwd: str) -> list[dict]:
    root = _find_commands_root(cwd)
    if not root:
        return []

    by_name: dict[str, dict] = {}
    for fp in _list_command_files(root):
        cmd = _load_command_file(root, fp)
        if not cmd:
            continue
        by_name[cmd["name"]] = cmd
        for alias in cmd.get("aliases", []):
            by_name[alias] = cmd

    unique: dict[str, dict] = {}
    for cmd in by_name.values():
        unique[cmd["name"]] = cmd

    return sorted(unique.values(), key=lambda c: c["name"])


def expand_command_template(
    template: str,
    command: str,
    args: list[str],
    parameters: list[str],
    cwd: str,
) -> str:
    out = template
    for i, key in enumerate(parameters):
        value = args[i] if i < len(args) else ""
        out = out.replace("{{" + key + "}}", value)
    out = out.replace("{{cwd}}", cwd)
    out = out.replace("{{command}}", command)
    out = out.replace("{{args}}", " ".join(args))
    return out.strip()


def resolve_custom_command_input(
    input_text: str, commands: list[dict]
) -> dict | None:
    trimmed = input_text.strip()
    if not trimmed.startswith("/"):
        return None

    body = trimmed[1:]
    space = body.find(" ")
    cmd_name = (body if space == -1 else body[:space]).lower()
    cmd_args = [] if space == -1 else [a for a in body[space + 1 :].strip().split() if a]

    lookup: dict[str, dict] = {}
    for cmd in commands:
        lookup[cmd["name"].lower()] = cmd
        for alias in cmd.get("aliases", []):
            lookup[alias.lower()] = cmd

    command = lookup.get(cmd_name)
    if not command:
        return None
    return {"command": command, "args": cmd_args}


def expand_custom_command(command: dict, args: list[str], cwd: str) -> str:
    return expand_command_template(
        command["body"],
        command["name"],
        args,
        command.get("parameters", []),
        cwd,
    )


def try_expand_slash_command(text: str, cwd: str) -> str | None:
    commands = load_custom_commands(cwd)
    resolved = resolve_custom_command_input(text, commands)
    if not resolved:
        return None
    return expand_custom_command(resolved["command"], resolved["args"], cwd)


def format_custom_command_catalog(cwd: str) -> str:
    commands = load_custom_commands(cwd)
    if not commands:
        return "No custom commands found in .jackal/commands/."

    lines = ["Custom commands:", ""]
    for cmd in commands:
        alias_text = (
            f" (aliases: {', '.join(cmd['aliases'])})" if cmd.get("aliases") else ""
        )
        lines.append(f"- /{cmd['name']}{alias_text} — {cmd['description']}")
    return "\n".join(lines)


def custom_command_slash_names(cwd: str) -> list[str]:
    names: set[str] = set()
    for cmd in load_custom_commands(cwd):
        names.add(f"/{cmd['name']}")
        for alias in cmd.get("aliases", []):
            names.add(f"/{alias}")
    return sorted(names)
